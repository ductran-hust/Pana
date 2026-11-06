// Báo cáo · in nội dung xem trước (ES module, import từ ReportDialog.razor).
//
// TẠM THỜI thay cho file PDF từ API: người dùng chọn "Lưu dưới dạng PDF" trong hộp thoại in.
//
// Cách in — giống màn In Pallet ID (pallet.js / printPalletArea), cách đã chạy ổn trên app:
//   • in trong 1 iframe ẩn, KHÔNG in trên trang chính;
//   • CSS của app trong app có các khối @media print (vd .no-print, ẩn overlay / modal…) làm báo cáo
//     in ra trắng -> chép CSS của trang sang iframe nhưng LỌC BỎ mọi khối @media print và @page;
//     theme, tokens, CSS isolation của component vẫn giữ để bản in giống màn xem trước;
//   • CSS in riêng của báo cáo (PRINT_CSS) thêm vào cuối;
//   • chờ ảnh + font, hoãn 1 nhịp rồi mới print() để Blazor kịp nhận kết quả trước khi hộp thoại
//     in chặn luồng JS; in xong xoá iframe.
// Chẩn đoán: localStorage.swmsPrintDebug = '1' -> ghi log + giữ iframe sau khi in.

const PRINT_CSS = `
@page { size: A4 portrait; margin: 0; }   /* margin 0 -> trình duyệt không in header / footer */
html, body {
  margin: 0 !important; padding: 0 !important; height: auto !important; min-height: 0 !important;
  overflow: visible !important; display: block !important; background: #fff !important;
}
* { -webkit-print-color-adjust: exact; print-color-adjust: exact; animation: none !important; transition: none !important; }
.rpt-print { padding: 0 8mm; font-size: 10px; }

/* Lề trên / dưới: thead / tfoot rỗng 10 mm của bảng khung lặp lại mỗi trang */
.rpt-print > table.pp { width: 100%; border-collapse: collapse; border: 0; }
.rpt-print > table.pp > thead { display: table-header-group !important; }
.rpt-print > table.pp > tfoot { display: table-footer-group !important; }
.rpt-print > table.pp > * > tr > td { padding: 0 !important; border: 0 !important; background: none !important; }
.rpt-print .pp-sp { height: 10mm; }

/* Khung xem trước (cuộn, flex, sticky) -> khối thường */
.rpt-print .pp-body > * {
  display: block !important; position: static !important;
  height: auto !important; max-height: none !important; min-height: 0 !important;
  overflow: visible !important; opacity: 1 !important; flex: none !important;
}
.rpt-print thead th, .rpt-print tfoot td { position: static !important; }
.rpt-print .pp-body thead { display: table-header-group; }   /* tiêu đề cột lặp lại mỗi trang */
.rpt-print .pp-body tfoot { display: table-row-group; }      /* dòng tổng in 1 lần ở cuối */
.rpt-print .pp-body table { width: 100%; }

/* Khổ dọc (~194 mm): chữ nhỏ, ô bảng gọn để bảng 10 cột không tràn */
.rpt-print .pp-body th, .rpt-print .pp-body td { padding: 4px 5px !important; font-size: 9.5px !important; white-space: normal; }
.rpt-print .pill { font-size: 9px !important; padding: 0 5px !important; }
.rpt-print .stv-row { grid-template-columns: 1fr !important; display: grid !important; }

/* Không cắt đôi khối */
.rpt-print tr, .rpt-print .doc-si, .rpt-print .stv-panel, .rpt-print .stv-info { break-inside: avoid; }
.rpt-print .doc-title, .rpt-print .rpt-sec-h, .rpt-print .stv-h { break-after: avoid; }

/* Căn thẳng 1 lề: bỏ padding ngang từng khối */
.rpt-print .doc { padding: 0 0 10px !important; border-bottom: 0 !important; }
.rpt-print .stv { background: #fff !important; padding: 6px 0 !important; border: 0; }
.rpt-print .stv-h, .rpt-print .rpt-sec-h { padding-left: 0 !important; padding-right: 0 !important; }
.rpt-print .rpt-table th:first-child, .rpt-print .rpt-table td:first-child { padding-left: 0 !important; }
.rpt-print .rpt-table th:last-child, .rpt-print .rpt-table td:last-child { padding-right: 0 !important; }
`;

const esc = (s) => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
const attrs = (el) => [...el.attributes].map(a => `${a.name}="${esc(a.value)}"`).join(' ');

let busy = false;

/** el: phần tử chứa nội dung xem trước. title: tên file gợi ý (không đuôi). */
export function printReport(el, title) {
    if (!el || busy) return false;
    busy = true;

    const debug = (() => { try { return localStorage.getItem('swmsPrintDebug') === '1'; } catch { return false; } })();
    const { css, links, skipped } = collectCss();

    // Nội dung: clone (giữ class + thuộc tính b-xxx của CSS isolation), bỏ trạng thái "mờ" của khung xem trước
    const copy = el.cloneNode(true);
    copy.classList.remove('dim');
    copy.removeAttribute('id');

    const frame = document.createElement('iframe');
    frame.setAttribute('aria-hidden', 'true');
    frame.style.cssText = 'position:fixed;right:0;bottom:0;width:0;height:0;border:0;';
    document.body.appendChild(frame);

    const doc = frame.contentWindow.document;
    doc.open();
    doc.write(`<!DOCTYPE html><html ${attrs(document.documentElement)}><head>
<meta charset="utf-8"><base href="${esc(document.baseURI)}"><title>${esc(title)}</title>
${links}
<style>${css}</style>
<style>${PRINT_CSS}</style>
</head><body ${attrs(document.body)}><div class="rpt-print"><table class="pp">
<thead><tr><td><div class="pp-sp"></div></td></tr></thead>
<tbody><tr><td class="pp-body"></td></tr></tbody>
<tfoot><tr><td><div class="pp-sp"></div></td></tr></tfoot>
</table></div></body></html>`);
    doc.close();
    doc.querySelector('.pp-body').appendChild(doc.importNode(copy, true));

    if (debug) {
        console.info('[swms-print]', {
            title, cssChars: css.length, externalLinks: (links.match(/<link/g) || []).length,
            skippedPrintRules: skipped, elements: copy.querySelectorAll('*').length,
        });
    }

    const win = frame.contentWindow;
    const oldTitle = document.title;
    let removed = false;
    const remove = () => {
        if (removed) return;
        removed = true;
        document.title = oldTitle;
        if (!debug) frame.remove();
        busy = false;
    };
    win.addEventListener('afterprint', () => setTimeout(remove, 300));

    const ready = Promise.all([
        ...[...doc.images].map(img => img.complete ? null : new Promise(r => { img.onload = img.onerror = r; })),
        ...[...doc.querySelectorAll('link[rel="stylesheet"]')].map(l => l.sheet ? null : new Promise(r => { l.onload = l.onerror = r; })),
        doc.fonts?.ready?.catch(() => { }),
    ]);
    const timeout = new Promise(r => setTimeout(r, 3000));

    Promise.race([ready, timeout]).then(() => {
        // Hoãn 1 nhịp để Blazor kịp nhận kết quả trước khi hộp thoại in chặn luồng JS
        setTimeout(() => {
            if (title) document.title = title;          // tên file gợi ý (Chrome lấy tiêu đề trang)
            try {
                win.focus();
                win.print();                            // Chrome / Edge: chặn tới khi đóng hộp thoại
            } finally {
                setTimeout(remove, 500);
            }
        }, 150);
    });
    return true;
}

/*  Gom CSS đang áp trên trang, BỎ các khối @media print / @page của app.
    url(...) tương đối được đổi sang tuyệt đối theo vị trí file CSS gốc (font, ảnh nền).
    Stylesheet khác origin không đọc được rule (CORS) -> giữ nguyên thẻ <link> (thường là font).  */
function collectCss() {
    let css = '', links = '', skipped = 0;

    const absUrls = (text, base) => !base ? text : text.replace(/url\(\s*(['"]?)([^'")]+)\1\s*\)/g, (m, q, u) => {
        if (/^(data:|blob:|https?:|\/\/|#)/i.test(u)) return m;
        try { return `url("${new URL(u, base).href}")`; } catch { return m; }
    });

    const walk = (rules, base) => {
        let out = '';
        for (const r of rules) {
            if (r instanceof CSSImportRule) {
                if (r.styleSheet && !/print/i.test(r.media?.mediaText ?? '')) {
                    try { out += walk(r.styleSheet.cssRules, r.styleSheet.href || base); } catch { /* khác origin */ }
                }
                continue;
            }
            if (r instanceof CSSPageRule) { skipped++; continue; }
            if (r instanceof CSSMediaRule) {
                const m = r.media.mediaText;
                if (/\bprint\b/i.test(m)) { skipped++; continue; }    // @media print của app
                out += `@media ${m}{${walk(r.cssRules, base)}}`;
                continue;
            }
            out += absUrls(r.cssText, base) + '\n';
        }
        return out;
    };

    for (const sheet of document.styleSheets) {
        if (sheet.disabled) continue;
        const media = sheet.media?.mediaText ?? '';
        if (/\bprint\b/i.test(media) && !/\b(all|screen)\b/i.test(media)) { skipped++; continue; }   // <link media="print">
        let rules;
        try { rules = sheet.cssRules; } catch { rules = null; }
        if (rules) css += walk(rules, sheet.href || document.baseURI);
        else if (sheet.href) links += `<link rel="stylesheet" href="${esc(sheet.href)}">\n`;
    }
    return { css, links, skipped };
}
