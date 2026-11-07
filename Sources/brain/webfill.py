"""Filling a field on a web page behind the owner's back: Tako's own fixed page code, run in the browser through Apple Events.

Accessibility can't write into a page's rich editors, and keys sent to a browser at the back go nowhere. The page itself can:
a plain or framework-controlled box takes its value through the element's own setter and an input event, a rich editor
(Lexical, ProseMirror, Slate, Quill, Draft) takes a paste event carrying the text once its content is selected. Nothing here
clicks, presses a key, submits or touches the clipboard; the text goes in as data (base64), never as code.
Each step is its own call: the page code runs apart from the page's own scripts, a promise comes back empty, and an editor
only takes in a new selection a moment later.
"""
from __future__ import annotations

import base64
import json
import re

# Browsers whose scripting runs page code, by bundle id. Their window is the one with the same title and frame as Tako's.
BROWSERS = {"com.google.Chrome": "Google Chrome"}
SETTLE = 0.4  # an editor takes in the selection on the next selectionchange, not at once

PAGE = r"""
(function (step, field, data, mark) {
  var text = data === null ? null : new TextDecoder().decode(Uint8Array.from(atob(data), function (c) { return c.charCodeAt(0); }));
  var say = function (o) { return JSON.stringify(o); };
  var squeeze = function (s) { return String(s || '').replace(/\s+/g, ''); };
  var TYPES = /^(text|search|email|url|tel|number|password)$/;
  var REFUSED = /password|cc-|one-time-code/;
  function rich(e) { return e.isContentEditable && !(e.parentElement && e.parentElement.isContentEditable); }
  function writable(e) {
    if (e.tagName === 'TEXTAREA') return true;
    if (e.tagName === 'INPUT') return TYPES.test((e.getAttribute('type') || 'text').toLowerCase());
    return rich(e);
  }
  function shown(e) {
    var r = e.getBoundingClientRect(), s = e.ownerDocument.defaultView.getComputedStyle(e);
    return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none';
  }
  function all(root, into) {
    var found = root.querySelectorAll('*');
    for (var i = 0; i < found.length; i++) {
      var e = found[i];
      if (writable(e)) into.push(e);
      if (e.shadowRoot) all(e.shadowRoot, into);
      if (e.tagName === 'IFRAME') { try { if (e.contentDocument) all(e.contentDocument, into); } catch (x) {} }
    }
    return into;
  }
  function own(e) {
    var words = ['aria-label', 'placeholder', 'aria-placeholder', 'data-placeholder', 'title', 'name', 'id'].map(function (a) { return e.getAttribute(a); });
    (e.labels || []).forEach(function (l) { words.push(l.innerText); });
    (e.getAttribute('aria-labelledby') || '').split(/\s+/).forEach(function (id) { var l = id && e.ownerDocument.getElementById(id); if (l) words.push(l.innerText); });
    return words.filter(function (w) { return w && w.trim(); }).map(function (w) { return w.trim(); });
  }
  // A rich editor's placeholder and a box's heading sit beside it, not on it.
  function around(e) {
    var near = [], up = e.parentElement, mine = (e.innerText || '').trim();
    for (var level = 0; up && level < 4; level++, up = up.parentElement) {
      var t = (up.innerText || '').replace(mine, '').trim();
      if (t && t.length <= 120) near.push(t);
    }
    return near;
  }
  function name(e) { return (own(e)[0] || around(e)[0] || e.tagName.toLowerCase()).slice(0, 40); }
  function score(e, want) {
    var best = 0;
    own(e).forEach(function (w) {
      w = w.toLowerCase();
      if (w === want) best = Math.max(best, 100);
      else if (w.indexOf(want) >= 0) best = Math.max(best, 70);
      else if (w.length >= 3 && want.indexOf(w) >= 0) best = Math.max(best, 50);
    });
    around(e).forEach(function (w, level) { if (w.toLowerCase().indexOf(want) >= 0) best = Math.max(best, 40 - 5 * level); });
    return best;
  }
  function focused() {
    var e = document.activeElement;
    while (e && (e.shadowRoot && e.shadowRoot.activeElement || e.tagName === 'IFRAME')) {
      try { e = e.shadowRoot && e.shadowRoot.activeElement ? e.shadowRoot.activeElement : e.contentDocument.activeElement; } catch (x) { break; }
    }
    while (e && e.isContentEditable && e.parentElement && e.parentElement.isContentEditable) e = e.parentElement;
    return e && writable(e) ? e : null;
  }
  function fields(list) { return list.filter(shown).map(name).filter(function (n, i, a) { return a.indexOf(n) === i; }).slice(0, 15); }
  function find() {
    var list = all(document, []);
    if (!field) {
      var here = focused();
      if (here) return {e: here};
      var seen = list.filter(shown);
      if (seen.length === 1) return {e: seen[0]};
      return {error: 'which', fields: fields(list)};
    }
    if (/^[#.\[]/.test(field)) { try { var picked = document.querySelector(field); if (picked && writable(picked)) return {e: picked}; } catch (x) {} }
    var want = field.trim().toLowerCase(), top = null, topScore = 0;
    list.forEach(function (e) {
      var s = score(e, want) + (shown(e) ? 5 : 0);
      if (s > topScore) { top = e; topScore = s; }
    });
    if (!top || topScore < 30) return {error: 'none', fields: fields(list)};
    return {e: top};
  }
  function kind(e) {
    if (!rich(e)) return 'box';
    if (e.getAttribute('data-lexical-editor')) return 'lexical';
    if (e.classList.contains('ProseMirror')) return 'prosemirror';
    if (e.getAttribute('data-slate-editor')) return 'slate';
    if (e.classList.contains('ql-editor')) return 'quill';
    if (e.closest('.DraftEditor-root')) return 'draft';
    return 'rich';
  }
  function now(e) { return rich(e) ? e.innerText : e.value; }
  function same(e) { return squeeze(now(e)) === squeeze(text); }
  function selectAll(e) {
    e.focus({preventScroll: true});
    var d = e.ownerDocument, r = d.createRange(), s = d.getSelection();
    r.selectNodeContents(e);
    s.removeAllRanges();
    s.addRange(r);
  }
  function marked() {
    var list = all(document, []);
    for (var i = 0; i < list.length; i++) if (list[i].getAttribute('data-tako-fill') === mark) return list[i];
    return null;
  }
  function report(e, extra) {
    var o = {kind: kind(e), name: name(e), now: String(now(e) || '').slice(0, 300), length: String(now(e) || '').length};
    for (var k in extra) o[k] = extra[k];
    return say(o);
  }

  if (step === 'start') {
    var hit = find();
    if (!hit.e) return say(hit);
    var e = hit.e;
    if (REFUSED.test(((e.getAttribute('type') || '') + ' ' + (e.getAttribute('autocomplete') || '')).toLowerCase())) return say({error: 'refused', name: name(e)});
    if (e.disabled || e.readOnly || e.getAttribute('aria-readonly') === 'true') return say({error: 'readonly', name: name(e)});
    if (!shown(e)) return say({error: 'hidden', name: name(e)});
    if (!rich(e)) {
      // A framework keeps its own copy of the value: the element's own setter goes round it, the input event tells it.
      var p = Object.getPrototypeOf(e), setter = null;
      while (p && !setter) { var d = Object.getOwnPropertyDescriptor(p, 'value'); setter = d && d.set; p = Object.getPrototypeOf(p); }
      setter.call(e, text);
      e.dispatchEvent(new Event('input', {bubbles: true}));
      e.dispatchEvent(new Event('change', {bubbles: true}));
      return report(e, {done: true, ok: same(e)});
    }
    e.setAttribute('data-tako-fill', mark);
    selectAll(e);
    return report(e, {pending: true});
  }
  var e = marked();
  if (!e) return say({error: 'gone'});
  if (step === 'paste') {
    e.dispatchEvent(new InputEvent('beforeinput', {inputType: 'deleteContentBackward', bubbles: true, cancelable: true}));
    if (text) {
      var dt = new DataTransfer();
      dt.setData('text/plain', text);
      e.dispatchEvent(new ClipboardEvent('paste', {clipboardData: dt, bubbles: true, cancelable: true}));
    }
    return say({ok: true});
  }
  if (step === 'reselect') { selectAll(e); return say({ok: true}); }
  if (step === 'type') {
    // An editor that ignored the paste: the browser's own editing, then the editor's own input event.
    if (!e.ownerDocument.execCommand(text ? 'insertText' : 'delete', false, text || undefined) || !same(e))
      e.dispatchEvent(new InputEvent('beforeinput', {inputType: 'insertText', data: text, bubbles: true, cancelable: true}));
    return say({ok: true});
  }
  if (step === 'check') {
    var done = same(e);
    if (done) e.removeAttribute('data-tako-fill');
    return report(e, {done: done, ok: done});
  }
  return say({error: 'step'});
})
"""


def page_code(step, field, text, mark):
    """One step of the fill as page code. The text and the field travel as data, so nothing in them can become code."""
    data = None if text is None else base64.b64encode(text.encode()).decode()
    return f"{PAGE.strip()}({json.dumps(step)}, {json.dumps(field or '')}, {json.dumps(data)}, {json.dumps(mark)})"


def quoted(source):
    """An AppleScript string: only backslash, quote and line breaks need escaping, and the page code is plain ASCII."""
    return '"' + source.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def windows_script(app):
    """Each window of the browser on its own line: id, the frame, the active tab's address and title."""
    # Inside the tell, `tab` is the browser's word for a tab, not the character.
    return ('set sep to character id 9\n'
            f'tell application {quoted(app)}\n'
            'set rows to {}\n'
            'repeat with w in windows\n'
            'set b to bounds of w\n'
            'set end of rows to ((id of w) as text) & sep & (item 1 of b) & sep & (item 2 of b) & sep & (item 3 of b) & sep & (item 4 of b) & sep & (URL of active tab of w) & sep & (title of active tab of w)\n'
            'end repeat\n'
            "set AppleScript's text item delimiters to linefeed\n"
            'return rows as text\n'
            'end tell')


def which_window(output, title, frame):
    """The browser window Tako means: the same frame first, then the same title. (id, address) or None."""
    rows = []
    for line in (output or "").strip().splitlines():
        parts = line.split("\t", 6)
        if len(parts) < 6:
            continue
        try:
            box = [float(n) for n in parts[1:5]]
        except ValueError:
            continue
        rows.append({"id": parts[0], "box": box, "url": parts[5], "title": parts[6] if len(parts) > 6 else ""})
    if frame:
        x, y, w, h = (float(frame.get(k, 0)) for k in ("x", "y", "w", "h"))
        near = [r for r in rows if all(abs(a - b) <= 4 for a, b in zip(r["box"], (x, y, x + w, y + h)))]
        if title:
            near = [r for r in near if r["title"] and (r["title"] in title or title in r["title"])] or near
        if len(near) == 1:
            return near[0]["id"], near[0]["url"]
    titled = [r for r in rows if title and r["title"] and (r["title"] == title or r["title"] in title)]
    if len(titled) == 1:
        return titled[0]["id"], titled[0]["url"]
    if len(rows) == 1:
        return rows[0]["id"], rows[0]["url"]
    return None


def run_script(app, window_id, step, field, text, mark):
    return f"tell application {quoted(app)} to execute active tab of window id {int(window_id)} javascript {quoted(page_code(step, field, text, mark))}"


def answer(output):
    """What the page code said, or what went wrong on the way."""
    try:
        return json.loads((output or "").strip() or "{}")
    except ValueError:
        return {"error": "unreadable", "raw": (output or "")[:200]}


def scripting_off(error):
    """The browser refuses page code until the owner turns it on once (View › Developer › Allow JavaScript from Apple Events)."""
    return bool(re.search(r"JavaScript.*(turned off|Apple Events|Apple 事件)|允许.*Apple 事件.*JavaScript", error or "", re.I | re.S))


# ---- handing files to a page's upload box (GitHub issue 3, 2026-11-07) ----
# Clicking an upload button opens the system's file chooser, which nothing behind the owner's back can work. The page's own
# file box takes files directly: the bytes come over in pieces as data (base64), become File objects in the page, and the box
# gets them the way a drop would, with the input and change events its uploader listens for. Nothing is clicked, except, when
# the box only appears on a click, the button the owner named, with the chooser it would open held back. Nothing is submitted.
CHUNK = 1_500_000            # bytes per call: about 2 MB of page code, well within what one Apple event carries
UPLOAD_LIMIT = 2_000_000_000  # the page holds every byte in memory until its uploader has read them
KINDS = {"video": (".mp4", ".mov", ".m4v", ".avi", ".wmv", ".flv", ".mkv", ".webm", ".3gp", ".mpg", ".mpeg"),
         "image": (".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".heic", ".tif", ".tiff", ".svg")}
TYPES = {".mp4": "video/mp4", ".mov": "video/quicktime", ".m4v": "video/x-m4v", ".avi": "video/x-msvideo", ".wmv": "video/x-ms-wmv",
         ".flv": "video/x-flv", ".mkv": "video/x-matroska", ".webm": "video/webm", ".3gp": "video/3gpp", ".mpg": "video/mpeg", ".mpeg": "video/mpeg",
         ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png", ".gif": "image/gif", ".webp": "image/webp", ".bmp": "image/bmp",
         ".heic": "image/heic", ".tif": "image/tiff", ".tiff": "image/tiff", ".svg": "image/svg+xml", ".pdf": "application/pdf",
         ".doc": "application/msword", ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
         ".xls": "application/vnd.ms-excel", ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
         ".ppt": "application/vnd.ms-powerpoint", ".pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
         ".zip": "application/zip", ".txt": "text/plain", ".csv": "text/csv", ".mp3": "audio/mpeg", ".m4a": "audio/mp4", ".wav": "audio/wav"}

UPLOAD = r"""
(function (step, field, data, mark) {
  var say = function (o) { return JSON.stringify(o); };
  var store = window.__takoUpload = window.__takoUpload || {};
  var KIND = {video: /video|\.(mp4|mov|m4v|avi|wmv|flv|mkv|webm|3gp|mpe?g)\b/i, image: /image|\.(jpe?g|png|gif|webp|bmp|heic|tiff?|svg)\b/i};
  var WORDS = {video: /视频|video/i, image: /图片|封面|照片|image|cover|photo|picture/i};
  function isFile(e) { return e.tagName === 'INPUT' && (e.getAttribute('type') || '').toLowerCase() === 'file'; }
  function walk(root, test, into) {
    var found = root.querySelectorAll('*');
    for (var i = 0; i < found.length; i++) {
      var e = found[i];
      if (test(e)) into.push(e);
      if (e.shadowRoot) walk(e.shadowRoot, test, into);
      if (e.tagName === 'IFRAME') { try { if (e.contentDocument) walk(e.contentDocument, test, into); } catch (x) {} }
    }
    return into;
  }
  function shown(e) {
    var r = e.getBoundingClientRect(), s = e.ownerDocument.defaultView.getComputedStyle(e);
    return r.width > 0 && r.height > 0 && s.visibility !== 'hidden' && s.display !== 'none';
  }
  function text(e) { return String(e.innerText || e.textContent || '').replace(/\s+/g, ' ').trim(); }
  function own(e) {
    var words = ['aria-label', 'title', 'name', 'id', 'accept'].map(function (a) { return e.getAttribute(a); });
    (e.labels || []).forEach(function (l) { words.push(text(l)); });
    return words.filter(function (w) { return w && w.trim(); });
  }
  // A file box is nearly always hidden inside the button or area it belongs to: what that area says is its name.
  function around(e) {
    var near = [], up = e.parentElement;
    for (var level = 0; up && level < 5; level++, up = up.parentElement) {
      var t = text(up);
      if (t && t.length <= 160) near.push(t);
    }
    return near;
  }
  function name(e) { return (around(e)[0] || own(e)[0] || 'file').slice(0, 40); }
  // Words on the page that say the name: buttons, labels, the text of an upload area.
  function labelled(want) {
    return walk(document, function (e) {
      var t = text(e);
      return shown(e) && t && t.length <= 40 && t.toLowerCase().indexOf(want) >= 0 && !e.querySelector('button, a, [role=button], input');
    }, []);
  }
  // How well a box answers to the name the model gave: its own words, or words in the area that holds it and no other box.
  function named(e, want) {
    var best = 0;
    own(e).forEach(function (w) { if (w.toLowerCase().indexOf(want) >= 0) best = Math.max(best, 70); });
    labelled(want).forEach(function (l) {
      var up = e.parentElement;
      for (var level = 0; up && level < 5; level++, up = up.parentElement) {
        if (walk(up, isFile, []).length > 1) break;  // an area with two boxes in it names neither
        if (up.contains(l)) { best = Math.max(best, 60 - 8 * level); break; }
      }
    });
    return best;
  }
  function score(e, want, kind) {
    var best = want ? named(e, want) : 0;
    var accept = e.getAttribute('accept') || '';
    if (kind && KIND[kind].test(accept)) best += 25;
    else if (kind && accept && !/\*\/\*|^\*$/.test(accept)) best -= 30;  // made for some other kind of file
    if (kind && around(e).slice(0, 2).some(function (w) { return WORDS[kind].test(w); })) best += 10;
    if (e.disabled) best -= 100;
    return best;
  }
  function boxes() { return walk(document, isFile, []); }
  function described(list) {
    return list.map(function (e) { return name(e) + (e.getAttribute('accept') ? '（' + e.getAttribute('accept').slice(0, 40) + '）' : ''); })
      .filter(function (n, i, a) { return a.indexOf(n) === i; }).slice(0, 12);
  }
  function marked() { var list = boxes(); for (var i = 0; i < list.length; i++) if (list[i].getAttribute('data-tako-upload') === mark) return list[i]; return null; }
  function pick(e, label) { e.setAttribute('data-tako-upload', mark); return say({found: true, name: label || name(e), accept: e.getAttribute('accept') || '', multiple: !!e.multiple}); }
  var meta = {};
  try { meta = data && step !== 'chunk' ? JSON.parse(data) : {}; } catch (x) {}
  var want = String(field || '').trim().toLowerCase();

  if (step === 'find') {
    var list = boxes(), top = null, topScore = -1;
    list.forEach(function (e) { var s = score(e, want, meta.kind); if (s > topScore) { top = e; topScore = s; } });
    // Named: the box must answer to the name itself, never only to the kind of file. Not named: the only box there is, or the one made for this kind.
    if (top && (want ? named(top, want) >= 30 && topScore >= 30 : (list.length === 1 && topScore > -50) || topScore >= 25)) return pick(top);
    var buttons = want ? labelled(want) : [];
    return say({error: buttons.length ? 'button' : (want ? 'none' : 'which'), boxes: described(list), button: buttons.length ? text(buttons[0]) : ''});
  }
  if (step === 'catch') {
    // The box appears only when its button is clicked. Clicked here, the chooser it would open is held back, and that box is the one.
    var caught = null, button = labelled(want)[0];
    if (!button) return say({error: 'none', boxes: described(boxes())});
    var hold = function (ev) { if (ev.target && isFile(ev.target)) { caught = ev.target; ev.preventDefault(); ev.stopImmediatePropagation(); } };
    window.addEventListener('click', hold, true);
    try { button.click(); } finally { window.removeEventListener('click', hold, true); }
    if (!caught) {
      var after = boxes().filter(function (e) { return !e.getAttribute('data-tako-upload') && named(e, want) >= 30; });
      if (after.length === 1) caught = after[0];
    }
    return caught ? pick(caught, text(button)) : say({error: 'nobox', button: text(button), boxes: described(boxes())});
  }
  if (step === 'file') {
    var box = marked();
    if (!box) return say({error: 'gone'});
    if (!store[mark]) store[mark] = [];
    store[mark].push({name: meta.name, type: meta.type || '', size: meta.size || 0, modified: meta.modified || Date.now(), parts: [], got: 0});
    return say({ok: true, files: store[mark].length});
  }
  if (step === 'chunk') {
    var files = store[mark];
    if (!files || !files.length) return say({error: 'lost'});
    var bytes = Uint8Array.from(atob(data), function (c) { return c.charCodeAt(0); });
    var f = files[files.length - 1];
    f.parts.push(bytes);
    f.got += bytes.length;
    return say({ok: true, got: f.got});
  }
  if (step === 'drop') { delete store[mark]; var left = marked(); if (left) left.removeAttribute('data-tako-upload'); return say({ok: true}); }
  if (step === 'set') {
    var box = marked(), files = store[mark];
    if (!box) return say({error: 'gone'});
    if (!files || !files.length) return say({error: 'lost'});
    var short = files.filter(function (f) { return f.got !== f.size; });
    if (short.length) return say({error: 'lost', name: short[0].name});
    if (files.length > 1 && !box.multiple) return say({error: 'single', name: name(box)});
    var accept = (box.getAttribute('accept') || '').split(',').map(function (a) { return a.trim().toLowerCase(); }).filter(Boolean);
    var fits = function (f) {
      if (!accept.length) return true;
      var lower = f.name.toLowerCase(), type = (f.type || '').toLowerCase();
      return accept.some(function (a) {
        if (a === '*' || a === '*/*') return true;
        if (a.charAt(0) === '.') return lower.slice(-a.length) === a;
        if (a.slice(-2) === '/*') return type.indexOf(a.slice(0, -1)) === 0;
        return type === a;
      });
    };
    var wrong = files.filter(function (f) { return !fits(f); });
    if (wrong.length) return say({error: 'accept', name: wrong[0].name, accept: accept.join(',')});
    var dt = new DataTransfer();
    files.forEach(function (f) { dt.items.add(new File(f.parts, f.name, {type: f.type, lastModified: f.modified})); });
    box.files = dt.files;
    box.dispatchEvent(new Event('input', {bubbles: true}));
    box.dispatchEvent(new Event('change', {bubbles: true}));
    delete store[mark];
    var given = Array.prototype.map.call(dt.files, function (f) { return f.name; });
    return say({ok: true, given: given, kept: box.files ? box.files.length : 0, name: name(box)});
  }
  if (step === 'check') {
    // What the page shows now: the file's name, a progress bar or a percentage, words for uploading, done or failed.
    var page = text(document.body), names = meta.names || [];
    var seen = names.filter(function (n) { var stem = n.replace(/\.[^.]+$/, ''); return page.indexOf(n) >= 0 || (stem.length >= 4 && page.indexOf(stem) >= 0); });
    var bars = walk(document, function (e) {
      return shown(e) && (e.tagName === 'PROGRESS' || e.getAttribute('role') === 'progressbar' || /(^|[\s_-])progress/i.test(String(e.className && e.className.baseVal !== undefined ? e.className.baseVal : e.className)));
    }, []).length;
    var percent = (page.match(/(\d{1,3}(?:\.\d+)?)\s?%/) || [])[1] || '';
    var snip = function (re) { var m = page.match(re); return m ? page.slice(Math.max(0, m.index - 20), m.index + m[0].length + 20) : ''; };
    return say({ok: true, seen: seen, bars: bars, percent: percent,
      uploading: snip(/上传中|正在上传|处理中|转码中|uploading|processing/i),
      done: snip(/上传成功|上传完成|已上传|upload(ed)? (complete|successful)|上传完毕/i),
      failed: snip(/上传失败|格式不支持|不支持该格式|超过.{0,6}(大小|限制)|文件过大|upload failed|too large|not supported/i),
      box: (function () { var b = marked(); return b ? (b.files ? b.files.length : 0) : -1; })()});
  }
  return say({error: 'step'});
})
"""

UPLOAD = UPLOAD.encode("ascii", "backslashreplace").decode()  # plain ASCII like PAGE: the Chinese words in it as \u escapes, which JS reads the same


def upload_code(step, field, data, mark):
    """One step of a hand-over as page code. File bytes, names and the field all travel as data (JSON or base64)."""
    data = data if isinstance(data, str) or data is None else json.dumps(data, ensure_ascii=True)
    return f"{UPLOAD.strip()}({json.dumps(step)}, {json.dumps(field or '')}, {json.dumps(data)}, {json.dumps(mark)})"


def upload_script(app, window_id, step, field, data, mark):
    return f"tell application {quoted(app)} to execute active tab of window id {int(window_id)} javascript {quoted(upload_code(step, field, data, mark))}"


def kind_of(paths):
    """What sort of file these all are, so the box made for it is picked: video, image, or '' when mixed or anything else."""
    kinds = {next((k for k, ends in KINDS.items() if str(p).lower().endswith(ends)), "") for p in paths}
    return kinds.pop() if len(kinds) == 1 else ""


def type_of(path):
    return TYPES.get("." + str(path).rsplit(".", 1)[-1].lower(), "") if "." in str(path) else ""
