defmodule ThreadIndexTest do
  use ExUnit.Case, async: true

  doctest ThreadIndex

  # Real desktop-Outlook-generated thread index (classic format, base64 "Adw...")
  @classic_index "AdwhchA3iY1ViNEfHkmwugPGkkvwHwAPfskPAFRy0/QAyxJQAAAwL3sAAGONHYQAC49qAAD2EKJgAAcIv4AAXtacAAAxEi1/ALo/J5w="

  # Real Exchange-Online/Graph-generated thread indexes (modern format, base64 "AQH...")
  @modern_index "AQHctryY3+i7P65pYUme3pKf8kZPArXI35KggAGSpwCAIkh3AIAABA4AgAFp9ICABNzTdIAAA2IAgABA+FSADIHEZ4AAAoIAgAAUJICAFC7C5YAOBJwAgANHAoE="
  @modern_index_2 "AQHc6TYSLtZGMVfdlUCnuaPyVxH6J7YYmsW9gAACQIyAASsQ+YAS6c0x"

  describe "decode/1 — published ground-truth vectors" do
    test "Meridian Discovery worked example decodes exactly" do
      # https://www.meridiandiscovery.com/how-to/e-mail-conversation-index-metadata-computer-forensics/
      # Published ground truth: header 2013-01-02 17:01:04 UTC,
      # reply 1 = 17:23:58 (random nibble 3), reply 2 = 17:25:53 (random nibble 6)
      index =
        "01CDE90ABFE0D78F0E4280824120B2F1D0E3C07ED0070000CCBA300000114460"
        |> Base.decode16!()
        |> Base.encode64()

      assert {:ok, result} = ThreadIndex.decode(index)
      assert result.format == :classic
      assert result.date == ~U[2013-01-02 17:01:04.168550Z]
      assert result.guid == Base.decode16!("D78F0E4280824120B2F1D0E3C07ED007")

      assert [reply1, reply2] = result.replies
      assert reply1.date == ~U[2013-01-02 17:23:58.065254Z]
      assert reply1.random == 0x30
      assert reply2.date == ~U[2013-01-02 17:25:53.932902Z]
      assert reply2.random == 0x60
    end

    test "Metaspike desktop-Outlook example decodes exactly" do
      # https://community.metaspike.com/t/thread-index-header-field/175
      # Published ground truth: header 2018-07-16 07:40:00.2799616 UTC,
      # child 2018-07-16 21:43:22.8275712 UTC
      assert {:ok, result} = ThreadIndex.decode("AdQc2DN7rLoS3hgnE/O76rpFzxN/EwAddF4A")

      assert result.format == :classic
      assert result.date == ~U[2018-07-16 07:40:00.279961Z]
      assert [reply] = result.replies
      assert reply.date == ~U[2018-07-16 21:43:22.827571Z]
    end

    test "Metaspike OWA/Exchange example decodes (child block publicly unsolved)" do
      # Same thread. The naive MS-OXOMSG child decoding produces a nonsense 2038
      # date for this vector and Meridian's own parser errors on it. The wrap
      # model recovers a reply composed 3m37s after the original message.
      assert {:ok, result} = ThreadIndex.decode("AQHWLRNo4NaOjvXU8EODe0ZotrA8B6itzaxf")

      assert result.format == :modern
      assert result.date == ~U[2020-05-18 12:54:02.646732Z]
      assert [reply] = result.replies
      assert reply.date == ~U[2020-05-18 12:57:39.754393Z]
    end
  end

  describe "decode/1 — real-world indexes" do
    test "classic (desktop Outlook) thread index" do
      assert {:ok, result} = ThreadIndex.decode(@classic_index)

      assert %ThreadIndex{format: :classic, date: date, guid: guid, replies: replies} = result
      assert date == ~U[2025-09-09 10:11:09.630054Z]
      assert byte_size(guid) == 16
      assert length(replies) == 11

      assert List.first(replies).date == ~U[2025-09-09 17:34:50.274611Z]
      assert List.last(replies).date == ~U[2025-09-30 05:09:00.689817Z]

      # Desktop Outlook emits small cumulative deltas with DC=0
      assert Enum.all?(replies, &(&1.delta_code == 0))

      dates = Enum.map(replies, & &1.date)
      assert dates == Enum.sort(dates, DateTime)
    end

    test "modern (Exchange Online / Graph) thread index" do
      assert {:ok, result} = ThreadIndex.decode(@modern_index)

      assert %ThreadIndex{format: :modern, date: date, guid: guid, replies: replies} = result
      assert date == ~U[2026-03-18 09:50:03.451596Z]
      assert guid == Base.decode16!("DFE8BB3FAE6961499EDE929FF2464F02")
      assert length(replies) == 14

      # Exchange always sets the delta code bit (MS-OXOMSG footnote <3>)
      assert Enum.all?(replies, &(&1.delta_code == 1))

      assert Enum.map(replies, & &1.date) == [
               ~U[2026-03-31 15:53:30.852147Z],
               ~U[2026-04-01 15:54:39.784550Z],
               ~U[2026-04-23 11:26:51.258470Z],
               ~U[2026-04-23 11:41:21.995980Z],
               ~U[2026-04-24 09:16:50.837708Z],
               ~U[2026-04-27 11:32:14.803148Z],
               ~U[2026-04-27 11:44:21.256601Z],
               ~U[2026-04-27 15:36:53.189427Z],
               ~U[2026-05-05 14:36:27.121868Z],
               ~U[2026-05-05 14:45:25.670502Z],
               ~U[2026-05-05 15:57:30.836787Z],
               ~U[2026-05-18 12:10:03.628339Z],
               ~U[2026-05-27 10:14:11.623526Z],
               ~U[2026-05-29 12:17:07.179315Z]
             ]
    end

    test "second modern thread index" do
      assert {:ok, result} = ThreadIndex.decode(@modern_index_2)

      assert result.format == :modern
      assert result.date == ~U[2026-05-21 15:25:35.376793Z]
      assert result.guid == Base.decode16!("2ED6463157DD9540A7B9A3F25711FA27")

      assert Enum.map(result.replies, & &1.date) == [
               ~U[2026-05-21 15:29:21.148313Z],
               ~U[2026-05-21 15:37:24.332134Z],
               ~U[2026-05-22 09:27:47.514982Z],
               ~U[2026-06-03 10:17:16.315443Z]
             ]
    end

    test "rejects invalid input" do
      assert ThreadIndex.decode("not base64!!!") == {:error, :invalid_base64}
      assert ThreadIndex.decode(Base.encode64(<<1, 2, 3>>)) == {:error, :invalid_length}

      assert ThreadIndex.decode(Base.encode64(:crypto.strong_rand_bytes(24))) ==
               {:error, :invalid_length}

      assert_raise ArgumentError, fn -> ThreadIndex.decode!("***") end
    end
  end

  describe "encode_reply/2 — byte compatibility with Microsoft encoders" do
    # Strip the last 5-byte child block from a real index, then re-append it
    # with encode_reply/2 using the decoded reply date (+ a sub-precision
    # offset) and the original random byte. The result must be byte-identical
    # to what Exchange / desktop Outlook actually produced.

    test "reproduces the child block Exchange Online appended (modern, DC=1 wrap)" do
      raw = Base.decode64!(@modern_index_2)
      prefix = binary_part(raw, 0, byte_size(raw) - 5)
      random = :binary.last(raw)

      {:ok, full} = ThreadIndex.decode(@modern_index_2)
      last = List.last(full.replies)

      reencoded =
        ThreadIndex.encode_reply(Base.encode64(prefix),
          time: DateTime.add(last.date, 500, :millisecond),
          random: random
        )

      assert reencoded == @modern_index_2
    end

    test "reproduces the child block desktop Outlook appended (classic, DC=0)" do
      raw = Base.decode64!(@classic_index)
      prefix = binary_part(raw, 0, byte_size(raw) - 5)
      random = :binary.last(raw)

      {:ok, full} = ThreadIndex.decode(@classic_index)
      last = List.last(full.replies)

      reencoded =
        ThreadIndex.encode_reply(Base.encode64(prefix),
          time: DateTime.add(last.date, 10, :millisecond),
          random: random
        )

      assert reencoded == @classic_index
    end
  end

  describe "encode_root/1" do
    test "generates a 22-byte classic header by default" do
      root = ThreadIndex.encode_root()

      assert byte_size(Base.decode64!(root)) == 22
      assert {:ok, %ThreadIndex{format: :classic, replies: []}} = ThreadIndex.decode(root)
    end

    test "generates a modern header on request" do
      root = ThreadIndex.encode_root(format: :modern, time: ~U[2026-01-01 12:00:00Z])

      assert <<1, 1, _::binary>> = Base.decode64!(root)
      assert {:ok, %ThreadIndex{format: :modern, date: date}} = ThreadIndex.decode(root)

      # modern headers truncate to 2^24 ticks (~1.68s)
      diff_us = DateTime.diff(~U[2026-01-01 12:00:00Z], date, :microsecond)
      assert diff_us >= 0 and diff_us < 1_700_000
    end

    test "round-trips GUID and date within the classic 6.55ms precision" do
      guid = :crypto.strong_rand_bytes(16)
      date = ~U[2025-01-15 12:30:45.123456Z]

      {:ok, result} = ThreadIndex.decode(ThreadIndex.encode_root(guid: guid, time: date))

      assert result.guid == guid
      diff_us = DateTime.diff(date, result.date, :microsecond)
      assert diff_us >= 0 and diff_us < 6554
    end

    test "rejects non-16-byte guids" do
      assert_raise ArgumentError, fn -> ThreadIndex.encode_root(guid: <<1, 2, 3>>) end
    end
  end

  describe "encode_reply/2 — round trips" do
    test "reply to a fresh root recovers the reply date within DC=0 precision" do
      root = ThreadIndex.encode_root(time: ~U[2025-01-01 10:00:00Z])
      reply_date = ~U[2025-01-01 11:00:00Z]

      {:ok, result} = ThreadIndex.decode(ThreadIndex.encode_reply(root, time: reply_date))

      assert [reply] = result.replies
      assert reply.delta_code == 0
      # masked current time (6.55ms) + DC=0 delta truncation (26.2ms)
      diff_us = DateTime.diff(reply_date, reply.date, :microsecond)
      assert diff_us >= 0 and diff_us < 40_000
    end

    test "reply to a modern (Graph) parent mirrors Exchange's wrapped encoding" do
      reply_date = ~U[2026-06-10 15:00:00Z]
      reply = ThreadIndex.encode_reply(@modern_index, time: reply_date)

      {:ok, parent} = ThreadIndex.decode(@modern_index)
      {:ok, result} = ThreadIndex.decode(reply)

      assert result.format == :modern
      assert result.date == parent.date
      assert result.guid == parent.guid
      assert length(result.replies) == 15

      # previous replies decode unchanged
      assert Enum.take(result.replies, 14) == parent.replies

      # the ~195y virtual delta forces DC=1, same as Exchange
      new_reply = List.last(result.replies)
      assert new_reply.delta_code == 1

      # round-trips within DC=1 precision (0.84s) + masked current time (6.55ms)
      diff_us = DateTime.diff(reply_date, new_reply.date, :microsecond)
      assert diff_us >= 0 and diff_us < 850_000
    end

    test "replies more than 1.7 years after the root use DC=1" do
      root = ThreadIndex.encode_root(time: ~U[2023-01-01 10:00:00Z])
      reply_date = ~U[2025-06-01 10:00:00Z]

      {:ok, result} = ThreadIndex.decode(ThreadIndex.encode_reply(root, time: reply_date))

      assert [reply] = result.replies
      assert reply.delta_code == 1

      diff_us = DateTime.diff(reply_date, reply.date, :microsecond)
      assert diff_us >= 0 and diff_us < 850_000
    end

    test "a chain of replies decodes monotonically and accurately" do
      root = ThreadIndex.encode_root(time: ~U[2025-01-01 10:00:00Z])

      reply_dates = [
        ~U[2025-01-01 10:10:00Z],
        ~U[2025-01-02 09:00:00Z],
        ~U[2025-03-15 18:30:00Z]
      ]

      index =
        Enum.reduce(reply_dates, root, fn date, acc ->
          ThreadIndex.encode_reply(acc, time: date)
        end)

      {:ok, result} = ThreadIndex.decode(index)
      assert length(result.replies) == 3

      result.replies
      |> Enum.zip(reply_dates)
      |> Enum.each(fn {reply, expected} ->
        # truncation accumulates along the chain: ~33ms per hop
        diff_us = DateTime.diff(expected, reply.date, :microsecond)
        assert diff_us >= 0 and diff_us < 120_000
      end)
    end
  end

  describe "decode_binary/1" do
    test "decodes raw PidTagConversationIndex bytes" do
      raw = Base.decode64!(@classic_index)

      assert {:ok, %ThreadIndex{format: :classic, date: ~U[2025-09-09 10:11:09.630054Z]}} =
               ThreadIndex.decode_binary(raw)
    end
  end
end
