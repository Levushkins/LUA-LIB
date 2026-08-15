-- moonhtml/ua.lua -- the user-agent stylesheet.
-- Defaults lean dark, because this renders on top of a game.
-- Everything here has the lowest priority and is trivially overridden.

return [[
html, body, div, section, header, footer, main, nav, aside, article,
p, h1, h2, h3, h4, h5, h6, ul, ol, form, fieldset, figure, blockquote,
hr, table, tr, dl, dt, dd, pre, details, summary {
  display: block;
}

body {
  margin: 0;
  padding: 0;
  font-family: default;
  font-size: 14px;
  line-height: 1.35;
  color: #e8eaed;
  background-color: transparent;
  box-sizing: border-box;
}

span, a, b, i, em, strong, small, code, label, img, u, s, mark, kbd, abbr {
  display: inline;
}

li { display: list-item; }
ul, ol { padding-left: 18px; margin: 6px 0; }
li { margin: 2px 0; }

h1 { font-size: 28px; font-weight: bold; margin: 10px 0 6px 0; }
h2 { font-size: 23px; font-weight: bold; margin: 9px 0 5px 0; }
h3 { font-size: 19px; font-weight: bold; margin: 8px 0 5px 0; }
h4 { font-size: 16px; font-weight: bold; margin: 7px 0 4px 0; }
h5 { font-size: 14px; font-weight: bold; margin: 6px 0 4px 0; }
h6 { font-size: 12px; font-weight: bold; margin: 6px 0 4px 0; }

p { margin: 6px 0; }
b, strong { font-weight: bold; }
i, em { font-style: italic; }
small { font-size: 11px; }
u { text-decoration: underline; }
s, strike, del { text-decoration: line-through; }
mark { background-color: #ffd54f; color: #202124; }
code, pre, kbd { font-family: mono; }
pre { white-space: pre; margin: 6px 0; }
blockquote { margin: 6px 0 6px 12px; padding-left: 8px; border-left: 2px solid #3c4043; }

a { color: #8ab4f8; cursor: pointer; text-decoration: none; }
a:hover { text-decoration: underline; }

hr {
  height: 1px;
  margin: 6px 0;
  background-color: #3c4043;
  border: none;
}

img { display: inline-block; }

button {
  display: inline-block;
  box-sizing: border-box;
  padding: 6px 12px;
  margin: 2px;
  border-radius: 4px;
  background-color: #3c4043;
  color: #e8eaed;
  text-align: center;
  cursor: pointer;
  border: none;
  transition: background-color 0.12s;
}
button:hover { background-color: #4a4f55; }
button:active { background-color: #5c6169; }
button:disabled { background-color: #2a2d31; color: #6b6f76; cursor: default; }

input, textarea, select {
  display: inline-block;
  box-sizing: border-box;
  padding: 5px 8px;
  margin: 2px;
  width: 180px;
  border-radius: 4px;
  background-color: #202124;
  color: #e8eaed;
  border: 1px solid #3c4043;
  cursor: text;
}
input:focus, textarea:focus, select:focus { border-color: #8ab4f8; }
select { cursor: pointer; }
textarea { height: 72px; }

input[type="checkbox"], input[type="radio"] {
  width: 16px;
  height: 16px;
  padding: 0;
  cursor: pointer;
  background-color: #202124;
  border: 1px solid #5f6368;
  vertical-align: middle;
}
input[type="checkbox"]:checked, input[type="radio"]:checked {
  background-color: #8ab4f8;
  border-color: #8ab4f8;
  color: #17181c;
}
input[type="radio"] { border-radius: 8px; }

input[type="range"] {
  width: 180px;
  height: 18px;
  padding: 0;
  border: none;
  background-color: transparent;
  cursor: pointer;
}

input[type="color"] {
  width: 36px;
  height: 20px;
  padding: 2px;
  cursor: pointer;
}

input[type="button"], input[type="submit"] {
  width: auto;
  cursor: pointer;
  background-color: #3c4043;
  text-align: center;
}

progress {
  display: block;
  width: 180px;
  height: 8px;
  border-radius: 4px;
  background-color: #202124;
  color: #8ab4f8;
}

table { display: block; }
th { font-weight: bold; text-align: left; }

script, style, head, meta, title, link, template { display: none; }
]]
