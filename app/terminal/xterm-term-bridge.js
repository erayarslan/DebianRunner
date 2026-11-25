/**
 * xterm-term-bridge.js — xterm.js terminal bridge for DebianRunner.
 *
 * Drop-in alternative to term.js (Ghostty). Uses the same native bridge API
 * (window.exports / webkit.messageHandlers) so the Obj-C host code stays
 * decoupled from the renderer.
 */

(async () => {
    'use strict';

    window.exports = {
        write() {},
        getSize: () => [0, 0],
        copy: () => '',
        linkAt: () => null,
        beginSelection: () => null,
        selectWordAt: () => null,
        extendSelection: () => null,
        beginSelectionHandle: () => null,
        moveSelectionHandle: () => null,
        endSelectionHandle() {},
        selectionGeometry: () => null,
        selectLine: () => null,
        selectAll: () => null,
        clearSelection() {},
        scrollByLines() {},
        scrollToLine() {},
        setFocused() {},
        scrollToBottom() {},
        newScrollTop() {},
        updateStyle() {},
        getCharacterSize: () => [0, 0],
        clearScrollback() {},
        setUserGesture() {},
        setAccessibilityEnabled() {},
    };

    const terminalElement = document.getElementById('terminal');
    const { Terminal, FitAddon, WebLinksAddon, LigaturesAddon } = window.xtermModules || {};
    const { CanvasAddon } = window.CanvasAddon || {};
    if (!Terminal || !FitAddon || !WebLinksAddon || !LigaturesAddon) {
        window.__terminalBootstrapLog?.('terminal xterm modules were not loaded');
        return;
    }
    if (!CanvasAddon) {
        window.__terminalBootstrapLog?.('terminal xterm canvas addon was not loaded');
        return;
    }

    const ansiColorNames = [
        'black',
        'red',
        'green',
        'yellow',
        'blue',
        'magenta',
        'cyan',
        'white',
        'brightBlack',
        'brightRed',
        'brightGreen',
        'brightYellow',
        'brightBlue',
        'brightMagenta',
        'brightCyan',
        'brightWhite',
    ];

    // ── Native bridge ────────────────────────────────────────────────────────
    const native = new Proxy({}, {
        get(_, prop) {
            return (...args) => {
                if (!window.webkit?.messageHandlers?.[prop])
                    return;
                let body = null;
                if (args.length == 1)
                    body = args[0];
                else if (args.length > 1)
                    body = args;
                window.webkit.messageHandlers[prop].postMessage(body);
            };
        }
    });

    // ── Style state ──────────────────────────────────────────────────────────
    let styleState = {
        foregroundColor: '#d4d4d4',
        backgroundColor: '#1e1e1e',
        cursorColor: undefined,
        fontSize: 12,
        fontFamily: '"JetBrainsMono Nerd Font Mono", "FiraCode Nerd Font Mono", ui-monospace, "SFMono-Regular", Menlo, Monaco, monospace',
        colorPaletteOverrides: undefined,
        blinkCursor: false,
        cursorShape: 'BLOCK',
    };
    styleState = {...styleState, ...normalizeStyleUpdate(window.__terminalInitialStyle)};
    applyDocumentStyle(styleState);
    await loadConfiguredFont(styleState);

    let resizeFrame = null;
    let pendingScrollSync = false;
    let lastNativeScrollHeight;
    let lastNativeScrollTop;
    let lastScrollStateSig = '';
    let suppressNativeScrollEcho = false;
    let nativeScrollRequest = null;
    let oldProps = {};
    let xtermAppActive = null;

    // Selection state in buffer linear coordinates (startIdx inclusive, endIdx exclusive)
    let dragAnchorCell = null;
    let dragWordRange = null; // { startIdx, endIdx } when press began on a word
    let dragMoved = false;
    let handleFixedIdx = null;
    let lastGeometrySignature = '';

    const NON_WORD_DELIMITERS = new Set(['"', "'", '`', '(', ')', '[', ']', '{', '}', '<', '>', ',', ';', '|']);
    const URL_CHARS_RE = /^[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+$/;
    const URL_MATCH_RE = /https?:\/\/[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+/gi;

    function isHttpUrl(candidate) {
        if (typeof candidate !== 'string' || !candidate)
            return false;
        try {
            const parsed = new URL(candidate);
            return parsed.protocol === 'http:' || parsed.protocol === 'https:';
        } catch {
            return false;
        }
    }

    // ── Terminal setup ───────────────────────────────────────────────────────
    const term = new Terminal({
        cols: 80,
        rows: 24,
        fontSize: styleState.fontSize,
        fontFamily: styleState.fontFamily,
        theme: themeForXterm(styleState),
        cursorBlink: styleState.blinkCursor,
        cursorStyle: cursorStyleForXterm(styleState.cursorShape),
        allowTransparency: true,
        scrollback: 10000,
        convertEol: false,
        disableStdin: true,  // iOS handles text input natively
        allowProposedApi: true,
        overviewRuler: {width: 0},
        smoothScrollDuration: 0,
        windowsMode: false,
        linkHandler: {
            activate(_event, uri) {
                if (isHttpUrl(uri))
                    native.openLink(uri);
            },
        },
    });

    const fitAddon = new FitAddon();
    term.loadAddon(new CanvasAddon());
    term.loadAddon(fitAddon);
    term.loadAddon(new WebLinksAddon((_event, uri) => {
        if (isHttpUrl(uri))
            native.openLink(uri);
    }));

    term.onData((data) => {
        native.sendInput(data);
        syncApplicationCursor();
    });
    term.onResize(() => {
        native.resize();
        scheduleScrollSync();
        notifySelection(true);
    });
    term.onScroll(() => {
        if (!suppressNativeScrollEcho)
            scheduleScrollSync();
        if (term.hasSelection())
            notifySelection(false);
    });
    term.onCursorMove(syncApplicationCursor);
    term.onSelectionChange(() => {
        native.selectionChanged(extractCleanSelection());
        notifySelection(false);
    });

    term.open(terminalElement);
    installNativeFocusAdapter();
    installLigatures();
    disableWebTextInput();
    fitAddon.fit();
    syncApplicationCursor();
    scheduleScrollSync();

    // ── Resize handling ──────────────────────────────────────────────────────
    function fitTerminal() {
        if (resizeFrame !== null)
            return;
        resizeFrame = requestAnimationFrame(() => {
            resizeFrame = null;
            fitAddon.fit();
            // The glyph atlas is built for the pixel density seen when the
            // terminal opened (1x while the web view was still offscreen);
            // WKWebView sends no DPR change, so rebuild it when the density
            // differs from the one the atlas was drawn at.
            if (window.devicePixelRatio !== fitTerminal.atlasRatio) {
                fitTerminal.atlasRatio = window.devicePixelRatio;
                term.clearTextureAtlas?.();
                term.refresh(0, term.rows - 1);
            }
            native.resize();
            scheduleScrollSync();
            if (term.hasSelection())
                notifySelection(true);
        });
    }

    const ro = new ResizeObserver(() => fitTerminal());
    ro.observe(terminalElement);

    // ── Selection helpers ────────────────────────────────────────────────────

    function cellChar(line, col) {
        if (!line || col < 0 || col >= term.cols)
            return '';
        const cell = line.getCell(col);
        if (!cell)
            return '';
        if (cell.getWidth() === 0 && col > 0) {
            const prev = line.getCell(col - 1);
            return prev ? prev.getChars() : '';
        }
        return cell.getChars();
    }

    function isBlankCell(line, col) {
        const ch = cellChar(line, col);
        return !ch || /^\s+$/.test(ch);
    }

    function isWordCell(line, col) {
        const ch = cellChar(line, col);
        if (!ch || /^\s+$/.test(ch))
            return false;
        return !NON_WORD_DELIMITERS.has(ch);
    }

    function lineTrimmedLength(line) {
        if (!line)
            return 0;
        let len = term.cols;
        while (len > 0 && isBlankCell(line, len - 1))
            len--;
        return len;
    }

    function getScreenMetrics() {
        const screen = terminalElement.querySelector('.xterm-screen');
        const cell = getCellSize();
        if (!screen || !cell.width || !cell.height)
            return null;
        return { screen, rect: screen.getBoundingClientRect(), cell };
    }

    function selectionCell(x, y) {
        const m = getScreenMetrics();
        if (!m || !Number.isFinite(x) || !Number.isFinite(y))
            return null;
        const buffer = term.buffer.active;
        const maxRow = Math.max(0, buffer.length - 1);
        const col = Math.max(0, Math.min(term.cols - 1, Math.floor((x - m.rect.left) / m.cell.width)));
        const visRow = Math.max(0, Math.min(term.rows - 1, Math.floor((y - m.rect.top) / m.cell.height)));
        return {
            col,
            row: Math.max(0, Math.min(maxRow, buffer.viewportY + visRow)),
        };
    }

    function selectionBoundary(x, y) {
        const m = getScreenMetrics();
        if (!m || !Number.isFinite(x) || !Number.isFinite(y))
            return null;
        const buffer = term.buffer.active;
        const maxRow = Math.max(0, buffer.length - 1);
        const col = Math.max(0, Math.min(term.cols, Math.round((x - m.rect.left) / m.cell.width)));
        const visRow = Math.max(0, Math.min(term.rows - 1, Math.floor((y - m.rect.top) / m.cell.height)));
        const row = Math.max(0, Math.min(maxRow, buffer.viewportY + visRow));
        return { col, row, idx: row * term.cols + col };
    }

    function wordRangeAt(cell) {
        if (!cell)
            return null;
        const buffer = term.buffer.active;
        const line = buffer.getLine(cell.row);
        if (!line)
            return null;
        let col = cell.col;
        // If finger landed just 1 cell right of a word on the same line, snap to it
        // only when that neighbor is non-blank and the tapped cell is trailing/inner space.
        if (isBlankCell(line, col)) {
            if (col > 0 && !isBlankCell(line, col - 1) && (col + 1 >= term.cols || isBlankCell(line, col + 1))) {
                // Keep empty area un-selected so long-pressing blank space offers Paste cleanly.
                return null;
            }
            return null;
        }
        const cols = term.cols;
        if (!isWordCell(line, col)) {
            // Tapped on a punctuation delimiter: select that single token.
            const idx = cell.row * cols + col;
            return { startIdx: idx, endIdx: idx + 1 };
        }
        let startCol = col;
        let endCol = col + 1;
        while (startCol > 0 && isWordCell(line, startCol - 1))
            startCol--;
        while (endCol < cols && isWordCell(line, endCol))
            endCol++;
        return {
            startIdx: cell.row * cols + startCol,
            endIdx: cell.row * cols + endCol,
        };
    }

    function currentLinearSelection() {
        const pos = term.getSelectionPosition();
        if (!pos)
            return null;
        const cols = term.cols;
        const startIdx = pos.start.y * cols + pos.start.x;
        const endIdx = pos.end.y * cols + pos.end.x;
        if (endIdx <= startIdx)
            return null;
        return { startIdx, endIdx };
    }

    function applyLinearSelection(startIdx, endIdx) {
        const cols = term.cols;
        const maxCells = term.buffer.active.length * cols;
        const s = Math.max(0, Math.min(maxCells - 1, startIdx));
        const e = Math.max(s + 1, Math.min(maxCells, endIdx));
        const startRow = Math.floor(s / cols);
        const startCol = s % cols;
        term.select(startCol, startRow, e - s);
    }

    // ── Link & Clean Multiline Copy Helpers ──────────────────────────────────

    function trimTrailingUrlPunctuation(raw) {
        let url = raw;
        while (url.length > 0) {
            const last = url[url.length - 1];
            if (last === '.' || last === ',' || last === ';' || last === ':' || last === '!' || last === '?' || last === "'" || last === '"') {
                url = url.slice(0, -1);
                continue;
            }
            if (last === ')') {
                const opens = (url.match(/\(/g) || []).length;
                const closes = (url.match(/\)/g) || []).length;
                if (closes > opens) { url = url.slice(0, -1); continue; }
            }
            if (last === ']') {
                const opens = (url.match(/\[/g) || []).length;
                const closes = (url.match(/\]/g) || []).length;
                if (closes > opens) { url = url.slice(0, -1); continue; }
            }
            break;
        }
        return url;
    }

    function oscLinkUriAtCell(row, col) {
        const oscService = term._core?._oscLinkService;
        if (!oscService || col < 0 || col >= term.cols)
            return null;
        const coreBuf = term._core?._bufferService?.buffer;
        const coreLine = coreBuf?.lines?.get?.(row);
        const nullCell = coreBuf?.getNullCell ? coreBuf.getNullCell() : null;
        const pubLine = term.buffer.active.getLine(row);
        if (!coreLine && !pubLine)
            return null;
        const readUrlId = (c) => {
            if (c < 0 || c >= term.cols)
                return 0;
            if (nullCell && coreLine?.loadCell) {
                coreLine.loadCell(c, nullCell);
                if (nullCell.hasExtendedAttrs?.() && nullCell.extended?.urlId)
                    return nullCell.extended.urlId;
            }
            const pubCell = pubLine?.getCell?.(c);
            return pubCell?._cell?.extended?.urlId || pubCell?.extended?.urlId || 0;
        };
        let urlId = readUrlId(col);
        if (!urlId && col > 0) {
            const pub = term.buffer.active.getLine(row)?.getCell?.(col);
            if (pub && pub.getWidth?.() === 0)
                urlId = readUrlId(col - 1);
        }
        if (!urlId)
            return null;
        const uri = oscService.getLinkData?.(urlId)?.uri;
        return isHttpUrl(uri) ? uri : null;
    }

    function isUrlContinuationSegment(trimmed) {
        if (!trimmed || /^https?:\/\//i.test(trimmed))
            return false;
        return URL_CHARS_RE.test(trimmed);
    }

    function plaintextLinkAtCell(row, col) {
        const buffer = term.buffer.active;
        if (!buffer || row < 0 || row >= buffer.length)
            return null;
        const maxRow = buffer.length - 1;

        // 1. Expand across terminal soft-wraps (isWrapped).
        let topRow = row;
        let botRow = row;
        while (topRow > 0 && buffer.getLine(topRow)?.isWrapped)
            topRow--;
        while (botRow < maxRow && buffer.getLine(botRow + 1)?.isWrapped)
            botRow++;

        // 2. Also handle hard-wrapped URLs (e.g. CLI/TUI wrapping long auth URLs with \r\n).
        const buildText = (fromRow, toRow, trimHardLines) => {
            let joined = '';
            const spans = [];
            for (let r = fromRow; r <= toRow; r++) {
                const line = buffer.getLine(r);
                if (!line) continue;
                const nextSoft = r < toRow && !!buffer.getLine(r + 1)?.isWrapped;
                const raw = line.translateToString(!nextSoft);
                if (!trimHardLines || line.isWrapped) {
                    const start = joined.length;
                    joined += raw;
                    spans.push({ row: r, colStart: 0, colEnd: raw.length, textStart: start, textEnd: joined.length });
                } else {
                    const lead = raw.length - raw.trimStart().length;
                    const trimmed = raw.trim();
                    const start = joined.length;
                    joined += trimmed;
                    spans.push({ row: r, colStart: lead, colEnd: lead + trimmed.length, textStart: start, textEnd: joined.length });
                }
            }
            return { joined, spans };
        };

        // Check soft-wrapped logical line first.
        let built = buildText(topRow, botRow, false);
        const tappedRowLine = buffer.getLine(row)?.translateToString(true)?.trim() || '';
        const looksLikeHardWrappedUrl =
            !(/https?:\/\//i.test(built.joined)) && isUrlContinuationSegment(tappedRowLine) ||
            (/https?:\/\/[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+$/i.test(built.joined.trim()));

        if (looksLikeHardWrappedUrl) {
            let hardTop = topRow;
            let hardBot = botRow;
            // Look upward up to 8 rows if current row is a continuation of a hard-wrapped URL.
            if (!/https?:\/\//i.test(built.joined)) {
                let probe = hardTop - 1;
                let foundStart = -1;
                while (probe >= Math.max(0, hardTop - 8)) {
                    const t = (buffer.getLine(probe)?.translateToString(true) || '').trim();
                    if (!t) break;
                    if (/https?:\/\/[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+$/i.test(t)) {
                        foundStart = probe;
                        break;
                    }
                    if (!isUrlContinuationSegment(t)) break;
                    probe--;
                }
                if (foundStart >= 0) {
                    hardTop = foundStart;
                    while (hardTop > 0 && buffer.getLine(hardTop)?.isWrapped)
                        hardTop--;
                }
            }
            // Extend downward up to 8 rows while lines are pure URL continuation segments.
            let probe = hardBot + 1;
            while (probe <= Math.min(maxRow, hardBot + 8)) {
                const line = buffer.getLine(probe);
                const t = (line?.translateToString(true) || '').trim();
                if (!t) break;
                if (line?.isWrapped || isUrlContinuationSegment(t)) {
                    hardBot = probe;
                    probe++;
                } else {
                    break;
                }
            }
            if (hardTop !== topRow || hardBot !== botRow) {
                built = buildText(hardTop, hardBot, true);
            }
        }

        const span = built.spans.find((s) => s.row === row);
        if (!span || col < span.colStart || col >= span.colEnd)
            return null;
        const tapOffset = span.textStart + (col - span.colStart);

        URL_MATCH_RE.lastIndex = 0;
        let match;
        while ((match = URL_MATCH_RE.exec(built.joined)) !== null) {
            const cleaned = trimTrailingUrlPunctuation(match[0]);
            const mStart = match.index;
            const mEnd = mStart + cleaned.length;
            if (tapOffset >= mStart && tapOffset < mEnd && isHttpUrl(cleaned)) {
                return { url: cleaned, kind: 'url' };
            }
        }
        return null;
    }

    function unwrapUrlLinesIfApplicable(logicalLines) {
        const nonEmpty = logicalLines.map((l) => l.trim()).filter(Boolean);
        if (nonEmpty.length === 0)
            return null;
        if (nonEmpty.length === 1) {
            const single = trimTrailingUrlPunctuation(nonEmpty[0]);
            return /^https?:\/\/\S+$/i.test(single) && isHttpUrl(single) ? single : null;
        }
        // Multiline selection of a wrapped auth URL (even if TUI added hard newlines,
        // left-padding spaces, or blank separator lines): join into one unbroken URL.
        const first = nonEmpty[0];
        if (!/^https?:\/\/[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+$/i.test(first))
            return null;
        for (let i = 1; i < nonEmpty.length; i++) {
            if (!isUrlContinuationSegment(nonEmpty[i]))
                return null;
        }
        const joined = trimTrailingUrlPunctuation(nonEmpty.join(''));
        return isHttpUrl(joined) ? joined : null;
    }

    function extractCleanSelection() {
        const range = currentLinearSelection();
        if (!range)
            return '';
        const buffer = term.buffer.active;
        const cols = term.cols;
        const startRow = Math.floor(range.startIdx / cols);
        const startCol = range.startIdx % cols;
        const lastIdx = range.endIdx - 1;
        const lastRow = Math.floor(lastIdx / cols);
        const lastColEnd = (lastIdx % cols) + 1;

        const logicalLines = [];
        for (let r = startRow; r <= lastRow; r++) {
            const line = buffer.getLine(r);
            if (!line) continue;
            const c0 = r === startRow ? startCol : 0;
            const c1 = r === lastRow ? lastColEnd : cols;
            const nextSoftWrapped = (r < lastRow) && !!buffer.getLine(r + 1)?.isWrapped;
            // Preserve trailing spaces when the row soft-wraps into the next row;
            // trim trailing blank cells on hard-ended lines so no ghost padding leaks.
            const segment = line.translateToString(!nextSoftWrapped, c0, c1).replace(/\u00a0/g, ' ');
            if (r > startRow && line.isWrapped && logicalLines.length > 0) {
                logicalLines[logicalLines.length - 1] += segment;
            } else {
                logicalLines.push(segment);
            }
        }

        // Drop accidental blank lines if the entire selection is a single wrapped URL.
        const unwrappedUrl = unwrapUrlLinesIfApplicable(logicalLines);
        if (unwrappedUrl)
            return unwrappedUrl;

        // Also stitch hard-wrapped URL continuations when a selection includes
        // leading label text (e.g. "Open: https://...\n&client_id=...").
        const stitched = [];
        for (let i = 0; i < logicalLines.length; i++) {
            const line = logicalLines[i];
            const trimmed = line.trim();
            if (stitched.length > 0 && isUrlContinuationSegment(trimmed)) {
                // Find the most recent non-empty line in stitched (allow 1 blank separator line inside a wrapped URL).
                let prevIdx = stitched.length - 1;
                if (stitched[prevIdx] === '' && prevIdx > 0)
                    prevIdx--;
                const prev = stitched[prevIdx];
                if (/https?:\/\/[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+$/i.test(prev.trimEnd())) {
                    if (prevIdx < stitched.length - 1)
                        stitched.pop(); // remove spurious blank separator inside wrapped URL
                    stitched[prevIdx] = prev.trimEnd() + trimmed;
                    continue;
                }
            }
            stitched.push(line);
        }

        // Trim trailing empty lines introduced by dragging slightly past row bounds.
        while (stitched.length > 1 && stitched[stitched.length - 1] === '')
            stitched.pop();
        return stitched.join('\n');
    }

    function linkUrlForSelection(range, cleanText) {
        if (!range)
            return '';
        const cols = term.cols;
        const startRow = Math.floor(range.startIdx / cols);
        const startCol = range.startIdx % cols;
        const oscUri = oscLinkUriAtCell(startRow, startCol);
        if (oscUri)
            return oscUri;
        const trimmed = (cleanText || '').trim();
        if (/^https?:\/\/\S+$/i.test(trimmed)) {
            const cleaned = trimTrailingUrlPunctuation(trimmed);
            if (isHttpUrl(cleaned))
                return cleaned;
        }
        // Also check if the selection lands inside a larger URL (e.g. double-tapped part of a URL).
        const midIdx = Math.floor((range.startIdx + range.endIdx - 1) / 2);
        const midRow = Math.floor(midIdx / cols);
        const midCol = midIdx % cols;
        const midOsc = oscLinkUriAtCell(midRow, midCol);
        if (midOsc)
            return midOsc;
        if (trimmed.length <= 2048) {
            URL_MATCH_RE.lastIndex = 0;
            const m = URL_MATCH_RE.exec(trimmed);
            if (m) {
                const cleaned = trimTrailingUrlPunctuation(m[0]);
                if (isHttpUrl(cleaned))
                    return cleaned;
            }
        }
        return '';
    }

    function getSelectionGeometry(extra) {
        const m = getScreenMetrics();
        const range = currentLinearSelection();
        const text = range ? extractCleanSelection() : '';
        if (!m || !range || !term.hasSelection()) {
            return Object.assign({
                hasSelection: false,
                text: '',
                linkUrl: '',
                cellWidth: m ? m.cell.width : 0,
                cellHeight: m ? m.cell.height : 0,
                startVisible: false,
                endVisible: false,
            }, extra || {});
        }
        const cols = term.cols;
        const vpY = term.buffer.active.viewportY;
        const startRow = Math.floor(range.startIdx / cols);
        const startCol = range.startIdx % cols;
        const lastIdx = range.endIdx - 1;
        const endRow = Math.floor(lastIdx / cols);
        const endCol = (lastIdx % cols) + 1;

        const startVisRow = startRow - vpY;
        const endVisRow = endRow - vpY;
        const startVisible = startVisRow >= 0 && startVisRow < term.rows;
        const endVisible = endVisRow >= 0 && endVisRow < term.rows;

        const startX = m.rect.left + startCol * m.cell.width;
        const startTopY = m.rect.top + startVisRow * m.cell.height;
        const startBottomY = startTopY + m.cell.height;

        const endX = m.rect.left + endCol * m.cell.width;
        const endTopY = m.rect.top + endVisRow * m.cell.height;
        const endBottomY = endTopY + m.cell.height;

        // Pick a clean anchor for the iOS edit menu inside the visible viewport.
        const visTopRow = Math.max(0, startVisRow);
        const visBottomRow = Math.min(term.rows - 1, endVisRow);
        let menuX;
        let menuY;
        if (visTopRow <= visBottomRow) {
            if (startRow === endRow && startVisible) {
                menuX = (startX + endX) / 2;
            } else {
                menuX = m.rect.left + m.rect.width / 2;
            }
            menuY = m.rect.top + visTopRow * m.cell.height;
        } else {
            menuX = m.rect.left + m.rect.width / 2;
            menuY = m.rect.top + m.rect.height / 2;
        }

        const linkUrl = linkUrlForSelection(range, text);

        return Object.assign({
            hasSelection: true,
            text,
            linkUrl,
            cellWidth: m.cell.width,
            cellHeight: m.cell.height,
            startX,
            startTopY,
            startBottomY,
            startVisible,
            endX,
            endTopY,
            endBottomY,
            endVisible,
            menuX,
            menuY,
        }, extra || {});
    }

    function notifySelection(force) {
        const geom = getSelectionGeometry();
        const sig = geom.hasSelection
            ? `${geom.startX.toFixed(1)},${geom.startTopY.toFixed(1)},${geom.endX.toFixed(1)},${geom.endTopY.toFixed(1)},${geom.startVisible},${geom.endVisible},${geom.text.length}`
            : 'none';
        if (force || sig !== lastGeometrySignature) {
            lastGeometrySignature = sig;
            native.selectionGeometry(geom);
        }
        return geom;
    }

    // ── Exports (native → JS) ────────────────────────────────────────────────
    function latin1StringToBytes(str) {
        const bytes = new Uint8Array(str.length);
        for (let i = 0; i < str.length; i++) {
            bytes[i] = str.charCodeAt(i) & 0xff;
        }
        return bytes;
    }

    window.exports = {
        write(data) {
            const bytes = typeof data === 'string' ? latin1StringToBytes(data) : new Uint8Array(data);
            const bufBefore = term.buffer.active;
            const wasAtBottom = bufBefore.type === 'normal' && bufBefore.viewportY >= bufBefore.baseY;
            term.write(bytes, () => {
                const bufAfter = term.buffer.active;
                if (wasAtBottom && bufAfter.type === 'normal' && bufAfter.viewportY < bufAfter.baseY) {
                    suppressNativeScrollEcho = true;
                    try {
                        term.scrollToBottom();
                    } finally {
                        suppressNativeScrollEcho = false;
                    }
                }
                scheduleScrollSync();
            });
            if (bytes.includes(0x1b))
                syncApplicationCursor();
        },
        getSize() {
            return [term.cols, term.rows];
        },
        copy() {
            return extractCleanSelection();
        },
        linkAt(x, y) {
            const cell = selectionCell(x, y);
            if (!cell)
                return null;
            const oscUri = oscLinkUriAtCell(cell.row, cell.col);
            if (oscUri)
                return { url: oscUri, kind: 'osc8', row: cell.row, col: cell.col };
            const plain = plaintextLinkAtCell(cell.row, cell.col);
            if (plain)
                return Object.assign(plain, { row: cell.row, col: cell.col });
            return null;
        },
        beginSelection(x, y) {
            const cell = selectionCell(x, y);
            dragAnchorCell = cell;
            dragMoved = false;
            dragWordRange = wordRangeAt(cell);
            if (dragWordRange) {
                applyLinearSelection(dragWordRange.startIdx, dragWordRange.endIdx);
            } else {
                term.clearSelection();
            }
            return notifySelection(true);
        },
        selectWordAt(x, y) {
            const cell = selectionCell(x, y);
            dragAnchorCell = cell;
            dragMoved = false;
            dragWordRange = wordRangeAt(cell);
            if (dragWordRange) {
                applyLinearSelection(dragWordRange.startIdx, dragWordRange.endIdx);
                return notifySelection(true);
            }
            return getSelectionGeometry();
        },
        extendSelection(x, y) {
            const end = selectionCell(x, y);
            if (!dragAnchorCell || !end)
                return getSelectionGeometry();
            if (!dragMoved && end.row === dragAnchorCell.row && end.col === dragAnchorCell.col && dragWordRange)
                return getSelectionGeometry();
            dragMoved = true;
            const cols = term.cols;
            const endCellIdx = end.row * cols + end.col;
            if (dragWordRange) {
                if (endCellIdx >= dragWordRange.startIdx) {
                    applyLinearSelection(dragWordRange.startIdx, Math.max(dragWordRange.endIdx, endCellIdx + 1));
                } else {
                    applyLinearSelection(endCellIdx, dragWordRange.endIdx);
                }
            } else {
                const anchorIdx = dragAnchorCell.row * cols + dragAnchorCell.col;
                const s = Math.min(anchorIdx, endCellIdx);
                const e = Math.max(anchorIdx, endCellIdx) + 1;
                applyLinearSelection(s, e);
            }
            return notifySelection(true);
        },
        beginSelectionHandle(which) {
            const range = currentLinearSelection();
            if (!range) {
                handleFixedIdx = null;
                return getSelectionGeometry();
            }
            handleFixedIdx = which === 'start' ? range.endIdx : range.startIdx;
            return getSelectionGeometry();
        },
        moveSelectionHandle(x, y) {
            const bound = selectionBoundary(x, y);
            if (handleFixedIdx === null || !bound)
                return getSelectionGeometry();
            const maxCells = term.buffer.active.length * term.cols;
            let startIdx;
            let endIdx;
            if (bound.idx < handleFixedIdx) {
                startIdx = bound.idx;
                endIdx = handleFixedIdx;
            } else if (bound.idx > handleFixedIdx) {
                startIdx = handleFixedIdx;
                endIdx = bound.idx;
            } else {
                startIdx = Math.max(0, Math.min(maxCells - 1, handleFixedIdx));
                endIdx = Math.min(maxCells, startIdx + 1);
            }
            applyLinearSelection(startIdx, endIdx);
            return notifySelection(true);
        },
        endSelectionHandle() {
            handleFixedIdx = null;
        },
        selectionGeometry() {
            return notifySelection(true);
        },
        selectLine() {
            const buffer = term.buffer.active;
            const maxRow = Math.max(0, buffer.length - 1);
            const range = currentLinearSelection();
            let startRow;
            let endRow;
            if (range) {
                startRow = Math.floor(range.startIdx / term.cols);
                endRow = Math.floor((range.endIdx - 1) / term.cols);
            } else if (dragAnchorCell) {
                startRow = endRow = dragAnchorCell.row;
            } else {
                startRow = endRow = Math.min(maxRow, buffer.baseY + buffer.cursorY);
            }
            while (startRow > 0 && buffer.getLine(startRow)?.isWrapped)
                startRow--;
            while (endRow < maxRow && buffer.getLine(endRow + 1)?.isWrapped)
                endRow++;
            const endLen = lineTrimmedLength(buffer.getLine(endRow));
            const endCol = endLen > 0 ? endLen : term.cols;
            applyLinearSelection(startRow * term.cols, endRow * term.cols + endCol);
            return notifySelection(true);
        },
        selectAll() {
            term.selectAll();
            return notifySelection(true);
        },
        clearSelection() {
            dragAnchorCell = null;
            dragWordRange = null;
            dragMoved = false;
            handleFixedIdx = null;
            term.clearSelection();
            notifySelection(true);
        },
        scrollByLines(delta) {
            if (!Number.isFinite(delta) || delta === 0)
                return;
            term.scrollLines(Math.trunc(delta));
            scheduleScrollSync();
            if (term.hasSelection())
                notifySelection(false);
        },
        scrollToLine(line) {
            if (!Number.isFinite(line))
                return;
            const buffer = term.buffer.active;
            const cellHeight = getCellSize().height;
            const clamped = Math.max(0, Math.min(buffer.baseY, Math.round(line)));
            if (clamped !== buffer.viewportY) {
                suppressNativeScrollEcho = true;
                try {
                    term.scrollToLine(clamped);
                } finally {
                    suppressNativeScrollEcho = false;
                }
            }
            if (cellHeight)
                lastNativeScrollTop = clamped * cellHeight;
            if (term.hasSelection())
                notifySelection(false);
        },
        setFocused(focused) {
            terminalElement.classList.toggle('terminal-focused', !!focused);
            setXtermAppActive(!!focused);
        },
        scrollToBottom() {
            suppressNativeScrollEcho = true;
            try {
                term.scrollToBottom();
            } finally {
                suppressNativeScrollEcho = false;
            }
            const cellHeight = getCellSize().height;
            if (cellHeight)
                lastNativeScrollTop = term.buffer.active.baseY * cellHeight;
            syncScroll();
        },
        newScrollTop(top) {
            if (!Number.isFinite(top))
                return;
            const cellHeight = getCellSize().height;
            if (!cellHeight)
                return;
            const buffer = term.buffer.active;
            const line = Math.max(0, Math.min(buffer.baseY, Math.round(top / cellHeight)));
            // UIKit owns fractional offsets and momentum. Do not echo scrollTop back.
            nativeScrollRequest = {buffer, line, cellHeight};
            suppressNativeScrollEcho = true;
            try {
                if (line !== buffer.viewportY)
                    term.scrollToLine(line);
            } finally {
                suppressNativeScrollEcho = false;
            }
            lastNativeScrollTop = line * cellHeight;
            if (term.hasSelection())
                notifySelection(false);
        },
        async updateStyle(newStyle) {
            styleState = {...styleState, ...normalizeStyleUpdate(newStyle)};
            applyDocumentStyle(styleState);
            await loadConfiguredFont(styleState);

            if (term.options.fontSize !== styleState.fontSize)
                term.options.fontSize = styleState.fontSize;
            if (term.options.fontFamily !== styleState.fontFamily)
                term.options.fontFamily = styleState.fontFamily;
            term.options.cursorBlink = !!styleState.blinkCursor;
            term.options.cursorStyle = cursorStyleForXterm(styleState.cursorShape);
            term.options.theme = themeForXterm(styleState);

            fitTerminal();
            term.refresh(0, term.rows - 1);
            scheduleScrollSync();
            if (term.hasSelection())
                notifySelection(true);
        },
        getCharacterSize() {
            const size = getCellSize();
            return [size.width || 0, size.height || 0];
        },
        clearScrollback() {
            term.clear();
            term.scrollToBottom();
            scheduleScrollSync();
        },
        setUserGesture() {},
        setAccessibilityEnabled() {},
    };

    // ── Signal ready ─────────────────────────────────────────────────────────
    setXtermAppActive(true);
    fitTerminal();
    native.load();
    native.syncFocus();

    function disableWebTextInput() {
        if (!term.textarea)
            return;
        term.textarea.readOnly = true;
        term.textarea.tabIndex = -1;
        term.textarea.autocapitalize = 'off';
        term.textarea.autocomplete = 'off';
        term.textarea.autocorrect = 'off';
        term.textarea.spellcheck = false;
    }

    function installLigatures() {
        try {
            term.loadAddon(new LigaturesAddon());
        } catch (error) {
            native.log(`terminal ligatures addon failed: ${error?.stack || error}`);
        }
    }

    function installNativeFocusAdapter() {
        const browserService = term._core?._coreBrowserService;
        if (!browserService)
            return;
        try {
            Object.defineProperty(browserService, 'isFocused', {
                configurable: true,
                get: () => !!xtermAppActive,
            });
        } catch (error) {
            native.log(`terminal focus adapter failed: ${error?.stack || error}`);
        }
    }

    function setXtermAppActive(active) {
        if (xtermAppActive === active) {
            if (active)
                ensureCursorVisible();
            return;
        }
        const hadPrev = xtermAppActive !== null;
        xtermAppActive = active;

        const core = term._core;
        try {
            if (core?.element)
                core.element.classList.toggle('focus', active);
            if (active) {
                core?._renderService?.handleFocus?.();
                if (hadPrev) {
                    // iOS WebKit can purge offscreen Canvas2D glyph atlases while
                    // backgrounded (e.g., switching to Safari for OAuth login).
                    term.clearTextureAtlas?.();
                    term.refresh(0, term.rows - 1);
                }
                ensureCursorVisible();
            } else {
                core?._renderService?.handleBlur?.();
            }
            if (hadPrev && core?.coreService?.decPrivateModes?.sendFocus) {
                native.sendInput(active ? '\x1b[I' : '\x1b[O');
            }
        } catch (error) {
            native.log(`terminal focus sync failed: ${error?.stack || error}`);
        }
    }

    function ensureCursorVisible() {
        const coreService = term._core?.coreService;
        if (coreService)
            coreService.isCursorInitialized = true;
        term.refresh(term.buffer.active.cursorY, term.buffer.active.cursorY);
    }

    function scheduleScrollSync() {
        if (pendingScrollSync)
            return;
        pendingScrollSync = true;
        requestAnimationFrame(() => {
            pendingScrollSync = false;
            syncScroll();
        });
    }

    function isMouseTrackingActive() {
        const mode = term.modes?.mouseTrackingMode;
        return !!mode && mode !== 'none';
    }

    function syncScroll() {
        const cellHeight = getCellSize().height;
        if (!cellHeight)
            return;
        const buffer = term.buffer.active;
        const altScreen = buffer.type === 'alternate';
        const mouseTracking = isMouseTrackingActive();
        // Fit rounds rows down; the unused fraction still belongs to UIKit's
        // viewport. Its maximum offset must equal baseY * cellHeight exactly.
        const scrollHeight = buffer.baseY * cellHeight + terminalElement.clientHeight;
        const scrollTop = buffer.viewportY * cellHeight;

        const stateSig = `${scrollHeight.toFixed(2)},${scrollTop.toFixed(2)},${cellHeight.toFixed(2)},${buffer.baseY},${buffer.viewportY},${altScreen ? 1 : 0},${mouseTracking ? 1 : 0}`;
        if (stateSig !== lastScrollStateSig) {
            lastScrollStateSig = stateSig;
            native.scrollState({
                scrollHeight,
                scrollTop,
                cellHeight,
                cellWidth: getCellSize().width,
                cols: term.cols,
                rows: term.rows,
                baseY: buffer.baseY,
                viewportY: buffer.viewportY,
                altScreen,
                mouseTracking,
            });
        }
        nativeScrollRequest = null;
        lastNativeScrollHeight = scrollHeight;
        lastNativeScrollTop = scrollTop;
        if (term.hasSelection())
            notifySelection(false);
    }

    function syncApplicationCursor() {
        syncProp('applicationCursor', !!term.modes?.applicationCursorKeysMode);
        syncProp('bracketedPaste', !!term.modes?.bracketedPasteMode);
    }

    function syncProp(name, value) {
        if (oldProps[name] !== value)
            native.propUpdate(name, value);
        oldProps[name] = value;
    }

    function getCellSize() {
        const dims = term._core?._renderService?.dimensions;
        return {
            width: dims?.css?.cell?.width || 0,
            height: dims?.css?.cell?.height || 0,
        };
    }

    function normalizeStyleUpdate(nextStyle) {
        const style = {...(nextStyle || {})};
        if (!Array.isArray(style.colorPaletteOverrides))
            style.colorPaletteOverrides = undefined;
        return style;
    }

    function applyDocumentStyle(style) {
        if (style.backgroundColor)
            document.documentElement.style.setProperty('--terminal-background', style.backgroundColor);
        if (style.foregroundColor)
            document.documentElement.style.setProperty('--terminal-foreground', style.foregroundColor);
    }

    async function loadConfiguredFont(style) {
        if (!document.fonts?.load)
            return;
        const family = firstFontFamily(style.fontFamily);
        if (!family)
            return;
        try {
            await Promise.all([
                document.fonts.load(`${style.fontSize}px ${quoteCssFontFamily(family)}`),
                document.fonts.load(`700 ${style.fontSize}px ${quoteCssFontFamily(family)}`),
            ]);
            await document.fonts.ready;
        } catch (error) {
            native.log(`terminal font load failed: ${error}`);
        }
    }

    function firstFontFamily(familyList) {
        const trimmed = String(familyList || '').trim();
        if (!trimmed)
            return '';
        const match = trimmed.match(/^(['"])(.*?)\1/);
        if (match)
            return match[2];
        return trimmed.split(',')[0].trim();
    }

    function quoteCssFontFamily(family) {
        const trimmed = String(family || '').trim();
        if (!trimmed || trimmed.startsWith('"') || trimmed.startsWith("'"))
            return trimmed;
        if (/^[a-zA-Z_-][a-zA-Z0-9_-]*$/.test(trimmed))
            return trimmed;
        return `"${trimmed.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
    }

    function cursorStyleForXterm(cursorShape) {
        switch (cursorShape) {
            case 'BEAM':
            case 'bar':
                return 'bar';
            case 'UNDERLINE':
            case 'underline':
                return 'underline';
            case 'BLOCK':
            case 'block':
            default:
                return 'block';
        }
    }

    function themeForXterm(style) {
        const theme = {
            foreground: style.foregroundColor,
            background: style.backgroundColor,
            cursor: style.cursorColor || style.foregroundColor,
            cursorAccent: style.backgroundColor,
            selectionBackground: 'rgba(56, 132, 255, 0.45)',
            selectionInactiveBackground: 'rgba(56, 132, 255, 0.35)',
        };
        if (Array.isArray(style.colorPaletteOverrides)) {
            for (let i = 0; i < Math.min(ansiColorNames.length, style.colorPaletteOverrides.length); i++)
                theme[ansiColorNames[i]] = style.colorPaletteOverrides[i];
        }
        return theme;
    }

})();
