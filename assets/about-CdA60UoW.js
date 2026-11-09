import{f as e}from"./index-ChXJvP0h.js";import{t}from"./jsx-runtime-73cbSzV3.js";import{n}from"./lib-C719NGBq.js";function r(r){let i={a:`a`,h2:`h2`,p:`p`,...n(),...r.components};return t(e,{children:[t(i.p,{children:`Models can read a picture perfectly well. What's missing is the plumbing: a
fast, continuous path from a camera to that reading, and a way to put something
back on the screen the person is actually looking at. That plumbing is what
gosslens is.`}),`
`,t(i.h2,{id:`why-one-core`,children:t(i.a,{href:`#why-one-core`,children:`Why one core`})}),`
`,t(i.p,{children:`Build a camera feature three times and you've got three products that happen to
share a name. Face tracking that drops a landmark on Android but not on iOS
isn't one feature, it's two implementations wearing the same label.`}),`
`,t(i.p,{children:`So everything that can live in the core does: scheduling, pools, triggers,
timestamps, codec choice, colour handling, the degradation ladder. The SDKs are
deliberately thin. If something could have been written in the core and ended
up in an SDK instead, we treat that as a bug rather than a shortcut.`}),`
`,t(i.h2,{id:`why-a-frozen-abi`,children:t(i.a,{href:`#why-a-frozen-abi`,children:`Why a frozen ABI`})}),`
`,t(i.p,{children:`Four SDKs and an unknown number of bindings people write themselves all talk to
the same library. If the boundary moved, every one of them would break, and
they'd break quietly: a struct read at the wrong offset usually produces a
number that looks plausible.`}),`
`,t(i.p,{children:`So the boundary is C, the layouts are fixed and asserted in the engine's own
tests, and fields only ever get added at the end behind a size field. You can
build against an older header and still run.`}),`
`,t(i.h2,{id:`why-it-stays-on-the-device`,children:t(i.a,{href:`#why-it-stays-on-the-device`,children:`Why it stays on the device`})}),`
`,t(i.p,{children:`There's no network code in the core. Not "we don't upload frames by default",
but there is nothing in there that could.`}),`
`,t(i.p,{children:`That's partly privacy and partly latency. A round trip to a server is longer
than a frame, so anything that needs to keep up with a camera has to happen
where the camera is.`}),`
`,t(i.h2,{id:`why-zig`,children:t(i.a,{href:`#why-zig`,children:`Why Zig`})}),`
`,t(i.p,{children:`The core needs to run on iOS, Android, the web through wasm, and desktop, with
no runtime and no garbage collector, and it needs to cross-compile to all of
them from one machine. Zig does that, and it's also the C compiler for every
vendored dependency, so there's one toolchain to pin rather than five.`}),`
`,t(i.p,{children:[`You never see any of this from an SDK. It matters when you're `,t(i.a,{href:`/docs/install/build`,children:`building from
source`}),` and nowhere else.`]})]})}function i(e={}){let{wrapper:i}={...n(),...e.components};return i?t(i,{...e,children:t(r,{...e})}):r(e)}export{i as default};
//# sourceMappingURL=about-CdA60UoW.js.map