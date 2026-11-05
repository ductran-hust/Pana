using Swms.FinishGoods.Web.Features.StowagePlan.Business.Models;

namespace Swms.FinishGoods.Web.Features.StowagePlan.Business;

/// <summary>
/// "Tự động xếp": soạn pallet → ghép cọc → xếp container, chạy hoàn toàn client-side.
///
/// Quy tắc (theo ghi chú màn hình):
///   • 1 SI / pallet; xếp hết model A rồi mới tới model B.
///   • Số box / pallet = box/tầng × số tầng vừa chiều cao tối đa (AIR 140, LCL 160, FCL ½ cont),
///     không quá layer_limit của model (nếu master.models có khai).
///   • SI chưa lấy hàng: thùng dự kiến tính từ số lượng / standard_packing (API dựng sẵn), xếp như box thật.
///   • ÍT PALLET NHẤT: mỗi model đủ pallet đầy cao thì đứng riêng; phần dư (vài tầng) của các model
///     cùng SI gom chung pallet (first-fit decreasing theo chiều cao), tầng dưới phải đầy:
///     mỗi pallet tối đa 1 tầng chưa đầy và tầng đó nằm trên cùng.
///   • Phần dư không ghép được: CHIA ĐỀU số tầng của model cho các pallet của nó (chênh tối đa 1 tầng).
///   • CHIA ĐỀU CHIỀU CAO mọi pallet của SI: giữ số pallet, chuyển tầng đầy từ pallet cao sang pallet thấp.
///   • Cọc: FCL ưu tiên dàn hết pallet đơn ra sàn tới tận cửa container; chỉ chồng cọc đôi khi sàn
///     số container tối thiểu thật sự không đủ (xếp thử, lấy số cọc đôi ít nhất). Cọc đôi: pallet dưới phải ĐẦY 1 mặt (không có tầng thiếu);
///     cả 2 đều đầy mặt thì pallet nặng hơn xuống dưới; tổng cao vừa lòng cont.
///     AIR/LCL không combine.
///   • Container: hàng sâu theo cọc (xoay ngang / dọc tuỳ ý, slip sheet / thùng rời theo mặt hộp), xếp tới tận cửa;
///     FCL cọc cao vào trong, thấp ra cửa; số container = max(theo chiều dài sàn, theo tải trọng),
///     hàng chia đều cho các container; cân trái / phải theo khối lượng.
/// Người dùng chỉnh tay tiếp ở 3 tab sau khi chạy.
/// </summary>
public static class StowageAutoPlanner
{
    public static void Run(StowageWorkspace ws)
    {
        ws.ResetBuild();
        BuildPallets(ws);
        BuildColumnsAndPlace(ws);
        ws.Commit();
    }

    // ── 1. Soạn pallet ───────────────────────────────────────
    // Mỗi SI riêng (1 SI / pallet). Đơn vị xếp là TẦNG (1 model, đủ 1 mặt; tầng thiếu luôn trên cùng):
    //   a. Mỗi model: số pallet đầy cao (đủ số tầng tối đa) đứng riêng 1 model.
    //   b. Phần dư của các model (vài tầng) gom lại bằng first-fit decreasing: phần dư cao nhất trước,
    //      đặt vào pallet dư đang cao nhất mà còn vừa -> ÍT PALLET NHẤT, ít model lẫn nhất.
    //      Điều kiện chung pallet: tổng cao ≤ chiều cao tối đa, tối đa 1 tầng thiếu,
    //      tổng số tầng ≤ layer_limit nhỏ nhất của các model trong pallet.
    //   c. Phần dư không ghép được với model khác -> chia đều lại số tầng của model đó
    //      cho các pallet của nó (chênh tối đa 1 tầng).
    //   d. CHIA ĐỀU CHIỀU CAO mọi pallet của SI (quy tắc 6, áp AIR / LCL / FCL): giữ nguyên số pallet,
    //      chuyển dần từng TẦNG ĐẦY từ pallet cao nhất sang pallet thấp nhất (chỉ khi sau khi chuyển
    //      pallet nhận vẫn thấp hơn pallet cho) -> không còn pallet 120 cm đứng cạnh pallet ghép 69 cm.
    //      Tầng thiếu không chuyển (vẫn nằm trên cùng); vẫn giữ cao tối đa và layer_limit;
    //      ưu tiên chuyển tầng của model đã có trên pallet nhận (ít lẫn model).
    private sealed class Layer
    {
        public string Model = "";
        public List<SwBox> Boxes = new();
        public double H;
        public bool Full;
        public int Limit;               // layer_limit của model (không khai = không giới hạn)
    }

    private sealed class Rem
    {
        public string Model = "";
        public List<Layer> Layers = new();
        public double LayerH;
        public double Height => Layers.Count * LayerH;
        public bool HasPartial;
        public int Limit;               // tổng tầng của pallet chứa model không quá layer_limit
        public int MaxLayers;
        public List<Layer> PureLayers = new();   // các tầng thuộc pallet đầy cao của model
        public int PureCount;
    }

    private sealed class Bin
    {
        public List<Rem> Parts = new();
        public double Height => Parts.Sum(p => p.Height);
        public int Layers => Parts.Sum(p => p.Layers.Count);
        public bool HasPartial => Parts.Any(p => p.HasPartial);
        public int Limit => Parts.Min(p => p.Limit);
    }

    private sealed class PalletStack
    {
        public List<Layer> Layers = new();
        public double Height => Layers.Sum(l => l.H);
        public int Limit => Layers.Count == 0 ? int.MaxValue : Layers.Min(l => l.Limit);
        public List<SwBox> Boxes => Layers.SelectMany(l => l.Boxes).ToList();
    }

    private static void BuildPallets(StowageWorkspace ws)
    {
        var siOrder = ws.Sis.Select((s, i) => (s.SiNo, i))
            .ToDictionary(x => x.SiNo, x => x.i, StringComparer.OrdinalIgnoreCase);

        var bySi = ws.Boxes.Values
            .GroupBy(b => b.SiNo, StringComparer.OrdinalIgnoreCase)
            .OrderBy(g => siOrder.GetValueOrDefault(g.Key, int.MaxValue));

        foreach (var si in bySi)
        {
            // Đế theo packing type của SI (PLASTIC PALLET, Paper pallet, SLIP SHEET, thùng rời…)
            var usableH = ws.MaxPalletHeight - StowageWorkspace.BaseHeightOf(ws.BaseOfSi(si.Key));

            // a–c: số pallet ít nhất
            var stacks = PackSi(ws, si.Key, si.ToList(), usableH);
            var pallets = stacks.Select(s => s.Boxes).ToList();

            // d. Chia đều chiều cao; bố trí thật sai quy tắc (cao quá / 2 tầng thiếu) thì giữ bản chưa chia
            if (Level(stacks, usableH))
            {
                var leveled = stacks.Select(s => s.Boxes).ToList();
                if (leveled.All(b =>
                    {
                        var lay = Probe(ws, si.Key, b);
                        return lay.Height <= ws.MaxPalletHeight + 0.01 && lay.PartialLayers <= 1;
                    }))
                    pallets = leveled;
            }

            foreach (var b in pallets) AddPallet(ws, si.Key, b);
        }
    }

    // a–c cho 1 SI với chiều cao xếp cho phép (không gồm đế) = cap.
    private static List<PalletStack> PackSi(StowageWorkspace ws, string siNo, List<SwBox> si, double cap)
    {
        var result = new List<PalletStack>();
        PalletStack Of(IEnumerable<Layer> layers) => new() { Layers = layers.ToList() };

        // a. Cắt từng model thành tầng; tách pallet đầy cao và phần dư
        var rems = new List<Rem>();
        foreach (var model in si.GroupBy(b => b.Model)
                     .OrderByDescending(g => g.First().L * g.First().W)
                     .ThenByDescending(g => g.First().Weight))
        {
            var boxes = model.OrderBy(b => b.BoxNo).ToList();
            var f = boxes[0];
            var maxLayers = Math.Max(1, (int)Math.Floor((cap + 0.01) / Math.Max(1, f.H)));
            var limit = f.LayerLimit is int lim && lim > 0 ? lim : int.MaxValue;
            maxLayers = Math.Min(maxLayers, limit);
            var perLayer = Math.Max(1, StowageWorkspace.PerLayer(f));

            var layers = new List<Layer>();
            for (var i = 0; i < boxes.Count; i += perLayer)
            {
                var lb = boxes.Skip(i).Take(perLayer).ToList();
                layers.Add(new Layer { Model = model.Key, Boxes = lb, H = f.H, Full = lb.Count == perLayer, Limit = limit });
            }

            var pureCount = layers.Count / maxLayers;
            var rest = layers.Skip(pureCount * maxLayers).ToList();
            rems.Add(new Rem
            {
                Model = model.Key,
                Layers = rest,
                LayerH = f.H,
                HasPartial = rest.Count > 0 && !rest[^1].Full,
                Limit = limit,
                MaxLayers = maxLayers,
                PureLayers = layers.Take(pureCount * maxLayers).ToList(),
                PureCount = pureCount,
            });
        }

        // b. Gom phần dư: cao nhất trước, vào pallet dư cao nhất còn vừa (best-fit)
        var bins = new List<Bin>();
        foreach (var r in rems.Where(r => r.Layers.Count > 0).OrderByDescending(r => r.Height).ThenByDescending(r => r.Layers.Count))
        {
            var target = bins
                .Where(b => b.Height + r.Height <= cap + 0.01
                            && !(b.HasPartial && r.HasPartial)
                            && b.Layers + r.Layers.Count <= Math.Min(b.Limit, r.Limit))
                .OrderByDescending(b => b.Height)
                .FirstOrDefault();
            if (target is null) bins.Add(target = new Bin());
            target.Parts.Add(r);
        }

        // c. Model có phần dư đứng riêng -> chia đều tầng cho các pallet của model
        var soloModels = bins.Where(b => b.Parts.Count == 1).Select(b => b.Parts[0]).ToHashSet();
        foreach (var r in rems)
        {
            if (soloModels.Contains(r) && r.PureCount > 0)
            {
                var all = r.PureLayers.Concat(r.Layers).ToList();      // tầng thiếu (nếu có) ở cuối
                var pallets = r.PureCount + 1;
                var baseLayers = all.Count / pallets;
                var extra = all.Count % pallets;
                var taken = 0;
                for (var i = 0; i < pallets; i++)
                {
                    var n = baseLayers + (i < extra ? 1 : 0);
                    result.Add(Of(all.Skip(taken).Take(n)));
                    taken += n;
                }
                continue;
            }

            for (var i = 0; i < r.PureCount; i++)
                result.Add(Of(r.PureLayers.Skip(i * r.MaxLayers).Take(r.MaxLayers)));
        }

        foreach (var bin in bins)
        {
            if (bin.Parts.Count == 1 && bin.Parts[0].PureCount > 0) continue;     // đã chia đều ở trên
            var stack = Of(bin.Parts.SelectMany(r => r.Layers));

            // Kiểm lại bằng bố trí thật (gộp theo cỡ thùng); sai quy tắc thì tách từng phần dư ra pallet riêng
            if (bin.Parts.Count > 1)
            {
                var lay = Probe(ws, siNo, stack.Boxes);
                if (lay.Height > ws.MaxPalletHeight + 0.01 || lay.PartialLayers > 1)
                {
                    foreach (var r in bin.Parts) result.Add(Of(r.Layers));
                    continue;
                }
            }
            result.Add(stack);
        }

        result.RemoveAll(s => s.Layers.Count == 0);
        return result;
    }

    // d. Chuyển tầng đầy từ pallet cao sang pallet thấp tới khi không còn bước nào làm 2 pallet gần nhau hơn.
    //    Mỗi bước: cao(nhận) + cao(tầng) < cao(cho) -> tổng bình phương chiều cao giảm thật -> luôn dừng.
    private static bool Level(List<PalletStack> stacks, double cap)
    {
        if (stacks.Count < 2) return false;
        var changed = false;

        for (var guard = 0; guard < 5000; guard++)
        {
            PalletStack? src = null, dst = null;
            Layer? pick = null;

            foreach (var a in stacks.OrderByDescending(s => s.Height))
            {
                if (a.Layers.Count < 2) continue;
                foreach (var b in stacks.OrderBy(s => s.Height))
                {
                    if (b.Height >= a.Height - 0.01) break;
                    pick = a.Layers
                        .Where(l => l.Full
                                    && b.Height + l.H < a.Height - 0.01
                                    && b.Height + l.H <= cap + 0.01
                                    && b.Layers.Count + 1 <= Math.Min(b.Limit, l.Limit))
                        .OrderByDescending(l => b.Layers.Any(x => x.Model == l.Model))                 // ít lẫn model
                        .ThenBy(l => Math.Abs((b.Height + l.H) - (a.Height - l.H)))                    // 2 pallet sát nhau nhất
                        .FirstOrDefault();
                    if (pick is null) continue;
                    src = a; dst = b;
                    break;
                }
                if (pick is not null) break;
            }

            if (pick is null || src is null || dst is null) break;
            src.Layers.Remove(pick);
            dst.Layers.Add(pick);
            changed = true;
        }

        return changed;
    }

    // Bố trí thử 1 nhóm thùng như 1 pallet (không thêm vào plan).
    private static PalletLayout Probe(StowageWorkspace ws, string siNo, List<SwBox> boxes)
    {
        var p = new SwPallet
        {
            Id = StowageWorkspace.NewId("TMP-CHK"),
            SiNo = siNo,
            BoxNos = boxes.Select(b => b.BoxNo).ToList(),
        };
        var lay = ws.Layout(p);
        ws.InvalidateLayout(p.Id);
        return lay;
    }

    private static SwPallet AddPallet(StowageWorkspace ws, string siNo, IEnumerable<SwBox> boxes)
    {
        var p = new SwPallet
        {
            Id = StowageWorkspace.NewId("TMP-PLT"),
            Code = StowageWorkspace.NextCode("P", ws.Pallets.Select(x => x.Code)),
            SiNo = siNo,
            BoxNos = boxes.Select(b => b.BoxNo).ToList(),
        };
        ws.Pallets.Add(p);
        return p;
    }

    // ── 2 + 3. Ghép cọc rồi xếp container ────────────────────
    // FCL ưu tiên DÀN HẾT pallet ra sàn tới tận cửa container, chỉ chồng khi sàn thật sự không đủ:
    //   1. C = số container ít nhất = max(khi chồng hết mức có thể, theo tải trọng) — xếp thử thật (Fill),
    //      không ước tính theo ô sàn.
    //   2. Tìm số cọc đôi ÍT NHẤT mà mọi cọc vẫn vừa C container -> sàn kín tới cửa, ít chồng nhất.
    // AIR / LCL không chồng: mọi pallet là cọc đơn.
    private static void BuildColumnsAndPlace(StowageWorkspace ws)
    {
        var n = ws.Pallets.Count;
        if (n == 0)
        {
            ws.ContainerCount = 1;
            return;
        }

        if (ws.NoCombine)
        {
            BuildColumns(ws, 0);
            PlaceColumns(ws, null);
            return;
        }

        var byWeight = (int)Math.Ceiling(ws.Pallets.Sum(p => ws.Layout(p).Weight) / Math.Max(1, ws.Spec.MaxPayload));

        int Needed(int doubles, int start)
        {
            ws.Columns.Clear();
            BuildColumns(ws, doubles);
            return Fill(ws, Order(ws), start, apply: false);
        }

        var maxDoubles = n / 2;
        var target = Math.Max(1, Math.Max(byWeight, Needed(maxDoubles, 1)));

        // Ít cọc đôi nhất mà vẫn vừa target container (càng ít chồng, pallet càng trải ra tới cửa)
        int lo = 0, hi = maxDoubles;
        while (lo < hi)
        {
            var mid = (lo + hi) / 2;
            if (Needed(mid, target) <= target) hi = mid; else lo = mid + 1;
        }

        ws.Columns.Clear();
        BuildColumns(ws, lo);
        PlaceColumns(ws, target);
    }

    // Cọc đôi: lấy từ các pallet thấp nhất, ghép cao + thấp để cọc đôi cao gần nhau;
    // pallet dưới phải đầy mặt; tổng cao phải vừa lòng cont.
    private static void BuildColumns(StowageWorkspace ws, int doublesNeeded)
    {
        var pool = ws.Pallets.OrderByDescending(p => ws.Layout(p).Weight).ToList();
        var n = pool.Count;
        if (n == 0) return;
        if (ws.NoCombine) doublesNeeded = 0;

        // Cọc đôi lấy từ các pallet THẤP nhất (dễ vừa chiều cao lòng cont).
        // Quy tắc: pallet dưới phải ĐẦY 1 mặt (không có tầng thiếu) → mỗi cọc đôi cần ít nhất 1 pallet FullTop.
        var byHeight = pool.OrderByDescending(p => ws.Layout(p).Height).ToList();
        var forDoubles = byHeight.Skip(Math.Max(0, byHeight.Count - doublesNeeded * 2)).ToList();   // thấp nhất
        var singles = byHeight.Take(byHeight.Count - forDoubles.Count).ToList();

        // Thiếu pallet đầy mặt để làm đáy → đổi pallet thiếu mặt cao nhất trong nhóm lấy pallet đầy mặt thấp nhất bên ngoài.
        var pairs = forDoubles.Count / 2;
        while (forDoubles.Count(p => ws.Layout(p).FullTop) < pairs)
        {
            var outFull = singles.Where(p => ws.Layout(p).FullTop).OrderBy(p => ws.Layout(p).Height).FirstOrDefault();
            var inOpen = forDoubles.Where(p => !ws.Layout(p).FullTop).OrderByDescending(p => ws.Layout(p).Height).FirstOrDefault();
            if (outFull is null || inOpen is null) break;
            singles.Remove(outFull); forDoubles.Add(outFull);
            forDoubles.Remove(inOpen); singles.Add(inOpen);
        }

        // Chia đáy / nóc: đáy = pallet đầy mặt nặng nhất; pallet thiếu mặt luôn nằm trên.
        var fulls = forDoubles.Where(p => ws.Layout(p).FullTop).OrderByDescending(p => ws.Layout(p).Weight).ToList();
        pairs = Math.Min(pairs, fulls.Count);
        var bottoms = fulls.Take(pairs).ToList();
        var tops = forDoubles.Except(bottoms)
            .OrderBy(p => ws.Layout(p).FullTop ? 1 : 0)                 // thiếu mặt được chọn làm nóc trước
            .ThenBy(p => ws.Layout(p).Height)
            .Take(pairs).ToList();
        singles.AddRange(forDoubles.Except(bottoms).Except(tops));

        // Ghép đáy cao nhất với nóc thấp nhất → các cọc đôi cao gần bằng nhau.
        bottoms = bottoms.OrderByDescending(p => ws.Layout(p).Height).ToList();
        tops = tops.OrderBy(p => ws.Layout(p).Height).ToList();
        for (var i = 0; i < pairs; i++)
        {
            SwPallet bottom = bottoms[i], top = tops[i];
            if (ws.Layout(bottom).Height + ws.Layout(top).Height > ws.Spec.InnerHeight)
            {
                singles.Add(bottom);
                singles.Add(top);
                continue;
            }
            // Cả 2 đều đầy mặt → pallet nặng hơn xuống dưới.
            if (ws.Layout(top).FullTop && ws.Layout(top).Weight > ws.Layout(bottom).Weight)
                (bottom, top) = (top, bottom);
            AddColumn(ws, bottom, top);
        }

        foreach (var single in singles.OrderByDescending(x => ws.Layout(x).Weight))
            AddColumn(ws, single, null);
    }

    private static void AddColumn(StowageWorkspace ws, SwPallet bottom, SwPallet? top)
        => ws.Columns.Add(new SwColumn
        {
            Id = StowageWorkspace.NewId("TMP-COL"),
            Code = StowageWorkspace.NextCode("C", ws.Columns.Select(c => c.Code)),
            Bottom = bottom.Id,
            Top = top?.Id,
        });

    // ── 3. Xếp container ─────────────────────────────────────
    // Sàn không còn chia ô cố định 120×100: mỗi hàng sâu bằng cọc sâu nhất trong hàng, cọc xoay ngang / dọc
    // tuỳ ý (slip sheet / thùng rời chiếm sàn theo mặt hộp) -> xếp nối tiếp tới tận cửa container.
    //   • FCL: cọc CAO vào trong (đầu cont), thấp dần ra cửa; 2 cọc cạnh nhau cao gần bằng nhau.
    //     AIR / LCL (không chồng): cọc nặng trước.
    //   • Mỗi hàng: thử ghép 2 cọc kế nhau (chọn hướng cho hàng nông nhất mà vừa bề ngang);
    //     hết chỗ cho cả hàng đôi thì đặt 1 cọc (xoay cho vừa phần dư sát cửa).
    //   • Nhiều container: lần 1 xếp nối tiếp để biết số container tối thiểu (và theo tải trọng),
    //     lần 2 chia hàng vào container đang ngắn nhất -> các container dài / tải gần bằng nhau,
    //     container nào cũng cao ở trong, thấp ở cửa.
    //   • Trong 1 container: cọc nặng hơn vào làn đang nhẹ hơn (cân trái / phải).
    private static void PlaceColumns(StowageWorkspace ws, int? containers)
    {
        if (ws.Columns.Count == 0)
        {
            ws.ContainerCount = 1;
            return;
        }

        var order = Order(ws);
        var byWeight = (int)Math.Ceiling(order.Sum(ws.ColumnWeight) / Math.Max(1, ws.Spec.MaxPayload));
        var start = containers ?? Math.Max(Fill(ws, order, 1, apply: false), byWeight);
        Fill(ws, order, Math.Max(1, start), apply: true);
    }

    /// <summary>FCL: cọc cao trước (vào trong); AIR / LCL: cọc nặng trước.</summary>
    private static List<SwColumn> Order(StowageWorkspace ws)
        => ws.NoCombine
            ? ws.Columns.OrderByDescending(ws.ColumnWeight).ToList()
            : ws.Columns.OrderByDescending(ws.ColumnHeight).ThenByDescending(ws.ColumnWeight).ToList();

    /// <summary>Chia cọc thành hàng và đặt vào <paramref name="start"/> container (thiếu chỗ thì mở thêm).
    /// Trả số container đã dùng; apply = ghi vào workspace.</summary>
    private static int Fill(StowageWorkspace ws, List<SwColumn> order, int start, bool apply)
    {
        double maxLen = ws.Spec.InnerLength, maxKg = ws.Spec.MaxPayload;
        var used = new List<double>();
        var load = new List<double>();
        var rows = new List<int>();
        var laneW = new List<double[]>();
        void Open()
        {
            used.Add(0);
            load.Add(0);
            rows.Add(0);
            laneW.Add(new double[Math.Max(1, ws.Lanes)]);
        }
        for (var i = 0; i < start; i++) Open();

        var placements = new List<SwPlacement>();
        void Put(int ci, SwColumn c, int lane, bool rot)
            => placements.Add(new SwPlacement { ContainerIndex = ci, Row = rows[ci], Lane = lane, ColumnId = c.Id, Rotated = rot });

        int Target(double depth, double kg) => Enumerable.Range(0, used.Count)
            .Where(i => used[i] + depth <= maxLen + 0.5 && rows[i] < StowageWorkspace.MaxRowIndex
                        && (load[i] + kg <= maxKg || used[i] == 0))
            .OrderBy(i => used[i]).ThenBy(i => load[i])
            .DefaultIfEmpty(-1).First();

        var queue = new List<SwColumn>(order);
        var guard = 0;
        while (queue.Count > 0 && guard++ < 10000)
        {
            var a = queue[0];
            var wa = ws.ColumnWeight(a);

            // Hàng đôi
            if (queue.Count > 1 && ws.Lanes >= 2 && BestPair(ws, a, queue[1]) is { } pr)
            {
                var b = queue[1];
                var wb = ws.ColumnWeight(b);
                var t = Target(pr.Depth, wa + wb);
                if (t >= 0)
                {
                    // cọc nặng vào làn đang nhẹ
                    var (heavy, hRot, light, lRot) = wa >= wb ? (a, pr.RotA, b, pr.RotB) : (b, pr.RotB, a, pr.RotA);
                    var lw = laneW[t];
                    var hl = lw[0] <= lw[lw.Length - 1] ? 0 : lw.Length - 1;
                    var ll = hl == 0 ? lw.Length - 1 : 0;
                    Put(t, heavy, hl, hRot);
                    Put(t, light, ll, lRot);
                    lw[hl] += ws.ColumnWeight(heavy);
                    lw[ll] += ws.ColumnWeight(light);
                    used[t] += pr.Depth;
                    load[t] += wa + wb;
                    rows[t]++;
                    queue.RemoveRange(0, 2);
                    continue;
                }
            }

            // 1 cọc (xoay cho vừa phần dư sát cửa)
            var (depth, rot) = BestSingle(ws, a);
            var ts = Target(depth, wa);
            if (ts >= 0)
            {
                var lw = laneW[ts];
                var lane = Array.IndexOf(lw, lw.Min());
                Put(ts, a, lane, rot);
                lw[lane] += wa;
                used[ts] += depth;
                load[ts] += wa;
                rows[ts]++;
                queue.RemoveAt(0);
                continue;
            }

            Open();     // không còn chỗ ở container nào -> mở container mới
        }

        if (apply)
        {
            ws.ContainerCount = used.Count;
            ws.Placements.AddRange(placements);
        }
        return used.Count;
    }

    /// <summary>Hướng đặt 2 cọc cạnh nhau cho hàng nông nhất mà tổng bề ngang vừa lòng cont; không vừa -> null.</summary>
    private static (double Depth, bool RotA, bool RotB)? BestPair(StowageWorkspace ws, SwColumn a, SwColumn b)
    {
        (double Depth, bool RotA, bool RotB)? best = null;
        var bestRot = int.MaxValue;
        foreach (var ra in new[] { false, true })
        foreach (var rb in new[] { false, true })
        {
            var ea = ws.Extent(a, ra);
            var eb = ws.Extent(b, rb);
            if (ea.Span + eb.Span > ws.Spec.InnerWidth + 0.5) continue;
            var d = Math.Max(ea.Depth, eb.Depth);
            var nRot = (ra ? 1 : 0) + (rb ? 1 : 0);
            if (best is null || d < best.Value.Depth - 0.01 || (Math.Abs(d - best.Value.Depth) < 0.01 && nRot < bestRot))
            {
                best = (d, ra, rb);
                bestRot = nRot;
            }
        }
        return best;
    }

    /// <summary>Hướng đặt 1 cọc: nông nhất mà vừa bề ngang (ưu tiên đặt dọc khi bằng nhau).</summary>
    private static (double Depth, bool Rot) BestSingle(StowageWorkspace ws, SwColumn c)
    {
        var straight = ws.Extent(c, false);
        var rotated = ws.Extent(c, true);
        var rotOk = rotated.Span <= ws.Spec.InnerWidth + 0.5;
        var strOk = straight.Span <= ws.Spec.InnerWidth + 0.5;
        if (rotOk && (!strOk || rotated.Depth < straight.Depth - 0.01)) return (rotated.Depth, true);
        return (straight.Depth, false);
    }
}
