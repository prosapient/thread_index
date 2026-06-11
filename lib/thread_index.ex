defmodule ThreadIndex do
  @moduledoc """
  Encode and decode the Outlook `Thread-Index` email header
  (MAPI `PidTagConversationIndex`, Microsoft Graph `conversationIndex`).

  A conversation index is a 22-byte header block followed by one 5-byte child
  block per reply, base64-encoded when transported in the `Thread-Index` MIME
  header. This library decodes both header variants found in the wild and
  encodes replies byte-compatible with what Outlook/Exchange themselves
  produce, so threads keep grouping and ordering correctly in Outlook.

  ## Format summary

  Header block (22 bytes): 6 time-derived bytes + 16-byte conversation GUID.
  Two variants exist (MS-OXOMSG 2.2.1.3 and its Appendix A footnote <2>):

    * `:classic` — desktop Outlook 2007-2019, Exchange 2007-2010. Bytes 0-5
      hold `FILETIME >>> 16` of the original message time (the leading byte is
      `0x01` for any date between 1829 and 2057 and doubles as the documented
      "reserved byte"). Base64 starts with `Ac`/`Ad`/`Ae`.

    * `:modern` — Exchange 2013+, Exchange Online, OWA, Graph API. Byte 0 is
      the reserved `0x01`, bytes 1-5 hold `FILETIME >>> 24`. Base64 starts
      with `AQ` (typically `AQH`).

  Child block (5 bytes): 1 bit delta code (DC), 31 bits time delta, 8 bits
  random. DC=0 stores `delta >>> 18` (26.2 ms units, max ~1.78 years), DC=1
  stores `delta >>> 23` (0.84 s units, max ~57 years).

  ## The two undocumented behaviors this library accounts for

  1. **Deltas are cumulative.** Each child's delta is relative to the
     accumulated time of the previous child block, not to the header (the
     MS-OXOMSG prose says "header", Microsoft's own code says otherwise).

  2. **Deltas chain from the classic read of the header — and wrap.** All
     Microsoft appenders (MAPI `cindex.c`, Exchange's `ConversationIndex`)
     compute the chain anchor by reading the header time bytes the classic
     way, even for `:modern` headers, where that read lands around year 1831.
     The resulting ~195-year virtual delta forces DC=1 and the 31-bit field
     silently truncates mod 2^31 — i.e. wraps modulo ~57 years (cf. footnote
     <3>: "Exchange 2013/2016/2019 set the Delta Code field to 1 and do not
     calculate the Time Delta field based on TimeDiff"). Decoding recovers
     true reply dates by re-running the same chain arithmetic and adding the
     minimal number of `2^(31+shift)`-tick wrap windows needed to land at or
     after the header date.

  Child timestamps record when each reply was *composed* (reply draft
  created), not when it was sent or delivered, so expect them to precede the
  displayed message times by the composition duration.

  ## Examples

      iex> {:ok, index} =
      ...>   "01CDE90ABFE0D78F0E4280824120B2F1D0E3C07ED0070000CCBA300000114460"
      ...>   |> Base.decode16!()
      ...>   |> Base.encode64()
      ...>   |> ThreadIndex.decode()
      iex> {index.format, index.date}
      {:classic, ~U[2013-01-02 17:01:04.168550Z]}
      iex> Enum.map(index.replies, & &1.date)
      [~U[2013-01-02 17:23:58.065254Z], ~U[2013-01-02 17:25:53.932902Z]]

  ## References

    * [MS-OXOMSG 2.2.1.3 PidTagConversationIndex](https://learn.microsoft.com/en-us/openspecs/exchange_server_protocols/ms-oxomsg/9e994fbb-b839-495f-84e3-2c8c02c7dd9b)
      and its Appendix A footnotes <2> and <3>
    * [MAPI "Tracking Conversations"](https://learn.microsoft.com/en-us/office/client-developer/outlook/mapi/tracking-conversations)
    * Microsoft MAPI SDK sample `cindex.c`; decompiled
      `Microsoft.Exchange.Data.Storage.ConversationIndex`
    * [Meridian Discovery: E-mail Conversation Index Analysis](https://www.meridiandiscovery.com/how-to/e-mail-conversation-index-metadata-computer-forensics/)
    * [Metaspike community: Thread-Index Header Field](https://community.metaspike.com/t/thread-index-header-field/175)
  """

  import Bitwise

  defmodule Reply do
    @moduledoc """
    One decoded 5-byte child block of a conversation index.

    `date` is the recovered absolute composition time of the reply.
    `random` is the raw 8-bit uniqueness field (legacy MAPI documentation
    splits it into a 4-bit random number and a 4-bit sequence count).
    """

    defstruct [:date, :delta_code, :random]

    @type t :: %__MODULE__{
            date: DateTime.t(),
            delta_code: 0 | 1,
            random: 0..255
          }
  end

  defstruct [:format, :date, :guid, replies: []]

  @type format :: :classic | :modern

  @type t :: %__MODULE__{
          format: format(),
          date: DateTime.t(),
          guid: <<_::128>>,
          replies: [Reply.t()]
        }

  # Windows FILETIME is 100ns ticks since 1601-01-01 00:00:00Z
  @epoch1601 ~U[1601-01-01 00:00:00Z]

  # DC=0 stores delta bits 48..18, DC=1 stores delta bits 53..23
  @dc0_shift 18
  @dc1_shift 23

  # When undoing the mod-2^31 wrap we aim for "at/after the header date", minus
  # this slack (~107s in FILETIME ticks) to absorb the down-truncation of the
  # low delta bits for replies composed moments after the original message.
  @wrap_slack 1 <<< 30

  @doc """
  Decodes a base64 `Thread-Index` value into a `t:ThreadIndex.t/0`.

  Returns `{:error, :invalid_base64}` if the input is not base64 and
  `{:error, :invalid_length}` if the decoded binary is not 22 + 5n bytes long.
  """
  @spec decode(String.t()) :: {:ok, t()} | {:error, :invalid_base64 | :invalid_length}
  def decode(base64) when is_binary(base64) do
    case Base.decode64(base64) do
      {:ok, raw} -> decode_binary(raw)
      :error -> {:error, :invalid_base64}
    end
  end

  @doc """
  Same as `decode/1` but raises `ArgumentError` on invalid input.
  """
  @spec decode!(String.t()) :: t()
  def decode!(base64) do
    case decode(base64) do
      {:ok, index} -> index
      {:error, reason} -> raise ArgumentError, "cannot decode thread index: #{reason}"
    end
  end

  @doc """
  Decodes a raw (not base64-encoded) conversation index binary, as found in
  the MAPI `PidTagConversationIndex` property.
  """
  @spec decode_binary(binary()) :: {:ok, t()} | {:error, :invalid_length}
  def decode_binary(<<first6::binary-size(6), guid::binary-size(16), rest::binary>>)
      when rem(byte_size(rest), 5) == 0 do
    format = header_format(first6)
    header_ft = header_filetime(format, first6)

    index = %__MODULE__{
      format: format,
      date: filetime_to_datetime(header_ft),
      guid: guid,
      replies: decode_children(rest, chain_anchor(first6), header_ft, [])
    }

    {:ok, index}
  end

  def decode_binary(raw) when is_binary(raw), do: {:error, :invalid_length}

  @doc """
  Encodes a 22-byte root conversation index for a new conversation thread.

  ## Options

    * `:time` — `DateTime` of the message, defaults to `DateTime.utc_now/0`
    * `:guid` — 16-byte conversation GUID, defaults to a random one
    * `:format` — `:classic` (default, desktop Outlook layout) or `:modern`
      (Exchange/OWA layout)

  ## Examples

      iex> guid = Base.decode16!("D78F0E4280824120B2F1D0E3C07ED007")
      iex> root = ThreadIndex.encode_root(guid: guid, time: ~U[2025-01-01 10:00:00Z])
      iex> ThreadIndex.decode!(root).date
      ~U[2025-01-01 09:59:59.997952Z]
  """
  @spec encode_root(keyword()) :: String.t()
  def encode_root(opts \\ []) do
    time = Keyword.get(opts, :time) || DateTime.utc_now()
    guid = Keyword.get(opts, :guid) || :crypto.strong_rand_bytes(16)
    format = Keyword.get(opts, :format, :classic)

    if byte_size(guid) != 16 do
      raise ArgumentError, "guid must be exactly 16 bytes, got #{byte_size(guid)}"
    end

    filetime = datetime_to_filetime(time)

    header =
      case format do
        :classic -> <<filetime >>> 16::unsigned-big-48>>
        :modern -> <<1, filetime >>> 24::unsigned-big-40>>
      end

    Base.encode64(header <> guid)
  end

  @doc """
  Appends a reply child block to an existing base64 conversation index,
  reproducing Microsoft's own arithmetic (see the moduledoc): the delta is
  computed against the cumulative chain anchored at the classic read of the
  header bytes, masked to 31 bits.

  The output is byte-compatible with what Outlook/Exchange would append for
  the same timestamps, so mixed threads stay consistent.

  ## Options

    * `:time` — `DateTime` of the reply, defaults to `DateTime.utc_now/0`
    * `:random` — the 8-bit uniqueness byte (0..255), defaults to a random
      value; pass it explicitly for reproducible output

  ## Examples

      iex> guid = Base.decode16!("D78F0E4280824120B2F1D0E3C07ED007")
      iex> root = ThreadIndex.encode_root(guid: guid, time: ~U[2025-01-01 10:00:00Z])
      iex> reply = ThreadIndex.encode_reply(root, time: ~U[2025-01-01 10:30:00Z], random: 0xAB)
      iex> [%ThreadIndex.Reply{delta_code: 0, random: 0xAB} = r] = ThreadIndex.decode!(reply).replies
      iex> r.date
      ~U[2025-01-01 10:29:59.983513Z]
  """
  @spec encode_reply(String.t(), keyword()) :: String.t()
  def encode_reply(parent_base64, opts \\ []) do
    time = Keyword.get(opts, :time) || DateTime.utc_now()
    random = Keyword.get(opts, :random) || :rand.uniform(256) - 1

    parent = Base.decode64!(parent_base64)
    <<first6::binary-size(6), _guid::binary-size(16), rest::binary>> = parent

    anchor = advance_chain(rest, chain_anchor(first6))

    # Mirror Microsoft's encoders (MAPI cindex.c / Exchange ConversationIndex):
    # current time with the low 16 bits masked off, absolute difference.
    diff = abs((datetime_to_filetime(time) &&& bnot(0xFFFF)) - anchor)

    # DC=0 only when the delta fits in 31 bits after dropping the low 18 bits
    # (< 2^49 ticks ~ 1.78 years; MS-OXOMSG tests this as "high order part of
    # the delta AND 0x00FE0000"). For modern-rooted threads the virtual delta
    # is ~195 years, so this is always DC=1 — same as Exchange.
    {dc, shift} = if diff < 1 <<< 49, do: {0, @dc0_shift}, else: {1, @dc1_shift}
    time_delta = diff >>> shift &&& 0x7FFFFFFF

    Base.encode64(<<parent::binary, dc::1, time_delta::unsigned-big-31, random::8>>)
  end

  # Modern headers carry the reserved 0x01 followed by the FILETIME high byte,
  # which is 0x01 until year 2057. Under the classic read, byte 1 holds
  # FILETIME bits 55..48, which is >= 0xB0 for any date after 1990 — so a
  # small byte 1 unambiguously identifies the modern variant.
  defp header_format(<<1, b1, _::binary>>) when b1 < 0x80, do: :modern
  defp header_format(_first6), do: :classic

  defp header_filetime(:modern, <<_reserved, ft_high40::unsigned-big-40>>), do: ft_high40 <<< 24
  defp header_filetime(:classic, <<ft_high48::unsigned-big-48>>), do: ft_high48 <<< 16

  # The anchor all real appenders chain child deltas from: the classic read,
  # regardless of the actual header variant.
  defp chain_anchor(<<ft_high48::unsigned-big-48>>), do: ft_high48 <<< 16

  defp decode_children(<<>>, _anchor, _header_ft, acc), do: Enum.reverse(acc)

  defp decode_children(
         <<dc::1, time_delta::unsigned-big-31, random::8, rest::binary>>,
         anchor,
         header_ft,
         acc
       ) do
    shift = if dc == 0, do: @dc0_shift, else: @dc1_shift
    anchor = anchor + (time_delta <<< shift)

    # Undo the mod-2^31 truncation: add the minimal number of wrap windows
    # required to land at/after the true header date (less a small slack,
    # since delta truncation may put a child marginally before it).
    window = 1 <<< (31 + shift)
    target = header_ft - @wrap_slack
    k = if anchor >= target, do: 0, else: div(target - anchor + window - 1, window)

    reply = %Reply{
      date: filetime_to_datetime(anchor + k * window),
      delta_code: dc,
      random: random
    }

    decode_children(rest, anchor, header_ft, [reply | acc])
  end

  defp advance_chain(<<>>, anchor), do: anchor

  defp advance_chain(<<dc::1, time_delta::unsigned-big-31, _random::8, rest::binary>>, anchor) do
    shift = if dc == 0, do: @dc0_shift, else: @dc1_shift
    advance_chain(rest, anchor + (time_delta <<< shift))
  end

  defp datetime_to_filetime(dt) do
    DateTime.diff(dt, @epoch1601, :microsecond) * 10
  end

  defp filetime_to_datetime(filetime) do
    DateTime.add(@epoch1601, div(filetime, 10), :microsecond)
  end
end
