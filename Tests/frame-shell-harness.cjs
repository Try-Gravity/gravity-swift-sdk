const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');

const source = fs.readFileSync(path.join(__dirname, '../Sources/GravitySDK/FrameShell.swift'), 'utf8');
const script = source.match(/<script>([\s\S]*?)<\/script>/)[1]
  .replace('\\(json)', JSON.stringify({ src: 'https://frames.example/test', generation: 'test' }));
let cases = 0;
for (const action of [undefined, 'primary', 'card:0', 'prompt']) {
  for (const active of [true, false, undefined]) {
    let receive;
    const sent = [];
    const frame = { contentWindow: {} };
    const window = {
      addEventListener: (_, callback) => { receive = callback; },
      webkit: { messageHandlers: { gravityFrame: { postMessage: value => sent.push(JSON.parse(value)) } } },
    };
    const navigator = active === undefined ? {} : { userActivation: { isActive: active } };
    vm.runInNewContext(script, { document: { querySelector: () => frame }, window, navigator });
    receive({ source: frame.contentWindow, data: { __gravity: 1, protocol: 'gfb-1', type: 'click', action } });
    assert.equal(sent.length, 1);
    assert.equal(sent[0].activated, active === undefined ? null : active);
    cases++;
  }
}
console.log(`PASS: ${cases} shell cases preserve true/false/unknown activation for ordinary, carousel, and prompt clicks.`);
