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
