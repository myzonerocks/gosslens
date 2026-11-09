import{f as e}from"./index-ChXJvP0h.js";import{t}from"./jsx-runtime-73cbSzV3.js";import{n}from"./lib-C719NGBq.js";function r(r){let i={a:`a`,code:`code`,h2:`h2`,p:`p`,pre:`pre`,span:`span`,...n(),...r.components},{Warning:o}=i;return o||a(`Warning`,!0),t(e,{children:[t(i.p,{children:[`The engine builds with a single pinned Zig release and nothing else. The pin
lives in `,t(i.code,{children:`.zigversion`}),`, and `,t(i.code,{children:`build.zig`}),` refuses any other compiler rather than
producing a binary nobody can reproduce.`]}),`
`,t(i.p,{children:`Fetch the pinned compiler, which is verified by digest:`}),`
`,t(e,{children:t(i.pre,{className:`shiki shiki-themes vitesse-light vitesse-dark`,style:{"--shiki-light":`#393a34`,"--shiki-dark":`#dbd7caee`,"--shiki-light-bg":`#ffffff`,"--shiki-dark-bg":`#121212`},tabIndex:`0`,children:t(i.code,{children:t(i.span,{className:`line`,children:t(i.span,{style:{"--shiki-light":`#59873A`,"--shiki-dark":`#80A665`},children:`tools/toolchain-sync`})})})})}),`
`,t(i.p,{children:`Then run the full local gate, which is the test suite, the ABI check, the
vendor licences and the conformance suite:`}),`
`,t(e,{children:t(i.pre,{className:`shiki shiki-themes vitesse-light vitesse-dark`,style:{"--shiki-light":`#393a34`,"--shiki-dark":`#dbd7caee`,"--shiki-light-bg":`#ffffff`,"--shiki-dark-bg":`#121212`},tabIndex:`0`,children:t(i.code,{children:t(i.span,{className:`line`,children:[t(i.span,{style:{"--shiki-light":`#59873A`,"--shiki-dark":`#80A665`},children:`zig`}),t(i.span,{style:{"--shiki-light":`#B56959`,"--shiki-dark":`#C98A7D`},children:` build`}),t(i.span,{style:{"--shiki-light":`#B56959`,"--shiki-dark":`#C98A7D`},children:` ci`})]})})})}),`
`,t(i.p,{children:`Zig is also the C and C++ compiler for every vendored dependency, so moving the
pin moves the whole native toolchain at once.`}),`
`,t(i.h2,{id:`per-target`,children:t(i.a,{href:`#per-target`,children:`Per target`})}),`
`,t(i.p,{children:[`One `,t(i.code,{children:`.so`}),` per Android ABI:`]}),`
`,t(e,{children:t(i.pre,{className:`shiki shiki-themes vitesse-light vitesse-dark`,style:{"--shiki-light":`#393a34`,"--shiki-dark":`#dbd7caee`,"--shiki-light-bg":`#ffffff`,"--shiki-dark-bg":`#121212`},tabIndex:`0`,children:t(i.code,{children:t(i.span,{className:`line`,children:[t(i.span,{style:{"--shiki-light":`#59873A`,"--shiki-dark":`#80A665`},children:`zig`}),t(i.span,{style:{"--shiki-light":`#B56959`,"--shiki-dark":`#C98A7D`},children:` build`}),t(i.span,{style:{"--shiki-light":`#B56959`,"--shiki-dark":`#C98A7D`},children:` android`})]})})})}),`
`,t(i.p,{children:`The iOS device slice:`}),`
`,t(e,{children:t(i.pre,{className:`shiki shiki-themes vitesse-light vitesse-dark`,style:{"--shiki-light":`#393a34`,"--shiki-dark":`#dbd7caee`,"--shiki-light-bg":`#ffffff`,"--shiki-dark-bg":`#121212`},tabIndex:`0`,children:t(i.code,{children:t(i.span,{className:`line`,children:[t(i.span,{style:{"--shiki-light":`#59873A`,"--shiki-dark":`#80A665`},children:`zig`}),t(i.span,{style:{"--shiki-light":`#B56959`,"--shiki-dark":`#C98A7D`},children:` build`}),t(i.span,{style:{"--shiki-light":`#B56959`,"--shiki-dark":`#C98A7D`},children:` ios`})]})})})}),`
`,t(i.p,{children:`The simulator slice:`}),`
`,t(e,{children:t(i.pre,{className:`shiki shiki-themes vitesse-light vitesse-dark`,style:{"--shiki-light":`#393a34`,"--shiki-dark":`#dbd7caee`,"--shiki-light-bg":`#ffffff`,"--shiki-dark-bg":`#121212`},tabIndex:`0`,children:t(i.code,{children:t(i.span,{className:`line`,children:[t(i.span,{style:{"--shiki-light":`#59873A`,"--shiki-dark":`#80A665`},children:`zig`}),t(i.span,{style:{"--shiki-light":`#B56959`,"--shiki-dark":`#C98A7D`},children:` build`}),t(i.span,{style:{"--shiki-light":`#B56959`,"--shiki-dark":`#C98A7D`},children:` ios-simulator`})]})})})}),`
`,t(i.p,{children:`The web engine:`}),`
`,t(e,{children:t(i.pre,{className:`shiki shiki-themes vitesse-light vitesse-dark`,style:{"--shiki-light":`#393a34`,"--shiki-dark":`#dbd7caee`,"--shiki-light-bg":`#ffffff`,"--shiki-dark-bg":`#121212`},tabIndex:`0`,children:t(i.code,{children:t(i.span,{className:`line`,children:[t(i.span,{style:{"--shiki-light":`#59873A`,"--shiki-dark":`#80A665`},children:`zig`}),t(i.span,{style:{"--shiki-light":`#B56959`,"--shiki-dark":`#C98A7D`},children:` build`}),t(i.span,{style:{"--shiki-light":`#B56959`,"--shiki-dark":`#C98A7D`},children:` wasm-emscripten`})]})})})}),`
`,t(o,{children:t(i.p,{children:`The vendored tree is large and some targets link the whole of it. A clean build
of the Android slices compiles the vendored C++ for each ABI in turn, which is
minutes rather than seconds.`})}),`
`,t(i.h2,{id:`gates`,children:t(i.a,{href:`#gates`,children:`Gates`})}),`
`,t(i.p,{children:[t(i.code,{children:`zig build ci`}),` is the bar a change has to clear: the test suite, the ABI diff
against the recorded baseline, the licence gate over every vendor pin, the fuzz
corpora, and the conformance suite against recorded frames. A red gate is
diagnosed rather than retried.`]})]})}function i(e={}){let{wrapper:i}={...n(),...e.components};return i?t(i,{...e,children:t(r,{...e})}):r(e)}function a(e,t){throw Error(`Expected `+(t?`component`:`object`)+" `"+e+"` to be defined: you likely forgot to import, pass, or provide it.")}export{i as default};
//# sourceMappingURL=build-si_dFYEN.js.map