import{f as e}from"./index-ChXJvP0h.js";import{t}from"./jsx-runtime-73cbSzV3.js";import{n}from"./lib-C719NGBq.js";function r(r){let i={a:`a`,code:`code`,h2:`h2`,li:`li`,ol:`ol`,p:`p`,strong:`strong`,table:`table`,tbody:`tbody`,td:`td`,th:`th`,thead:`thead`,tr:`tr`,...n(),...r.components},{Tip:o}=i;return o||a(`Tip`,!0),t(e,{children:[t(i.p,{children:`gosslens is a real-time vision engine for camera apps. You hand it frames, it
tells you what's in them, and you draw straight back onto them. Everything
happens on the device.`}),`
`,t(i.p,{children:`The core is written in Zig and everything crosses a single C ABI, so the Swift,
Kotlin and TypeScript SDKs are thin wrappers over exactly the same code. If
your language isn't one of those, you can write your own binding in an
afternoon.`}),`
`,t(o,{children:t(i.p,{children:[`If you've got ten minutes, the `,t(i.a,{href:`/docs/start/quickstart`,children:`quickstart`}),` gets one
frame through the engine and one overlay back.`]})}),`
`,t(i.h2,{id:`where-to-start`,children:t(i.a,{href:`#where-to-start`,children:`Where to start`})}),`
`,t(i.table,{children:[t(i.thead,{children:t(i.tr,{children:[t(i.th,{children:`If you're`}),t(i.th,{children:`Start here`})]})}),t(i.tbody,{children:[t(i.tr,{children:[t(i.td,{children:`Adding it to an app`}),t(i.td,{children:[t(i.a,{href:`/docs/install/sdks`,children:`Add an SDK`}),`, then your language's page`]})]}),t(i.tr,{children:[t(i.td,{children:`Running your own model`}),t(i.td,{children:t(i.a,{href:`/docs/build/models`,children:`Bring your own model`})})]}),t(i.tr,{children:[t(i.td,{children:`Placing things in a room`}),t(i.td,{children:t(i.a,{href:`/docs/build/ar`,children:`Building in AR`})})]}),t(i.tr,{children:[t(i.td,{children:`Reading faces, hands or text`}),t(i.td,{children:t(i.a,{href:`/docs/build/tracking`,children:`Tracking and text`})})]}),t(i.tr,{children:[t(i.td,{children:`Saving what the user sees`}),t(i.td,{children:t(i.a,{href:`/docs/build/capture`,children:`Capture and recording`})})]}),t(i.tr,{children:[t(i.td,{children:`Writing a binding`}),t(i.td,{children:t(i.a,{href:`/docs/binding/writing-an-sdk`,children:`Writing your own SDK`})})]})]})]}),`
`,t(i.h2,{id:`what-goes-in-and-what-comes-out`,children:t(i.a,{href:`#what-goes-in-and-what-comes-out`,children:`What goes in and what comes out`})}),`
`,t(i.p,{children:[`A frame goes in as whatever your platform already has. On Apple that's a
`,t(i.code,{children:`CVPixelBuffer`}),`, on Android an `,t(i.code,{children:`AHardwareBuffer`}),`, on the web a WebGL or WebGPU
texture. None of these get copied on the way in.`]}),`
`,t(i.p,{children:`What you get back is a record of what the engine found: faces, hands,
segmentation masks, detections, text with its reading order, planes, anchors,
depth. If a lens is active, you also get the rendered frame with whatever it
drew.`}),`
`,t(i.h2,{id:`who-does-what`,children:t(i.a,{href:`#who-does-what`,children:`Who does what`})}),`
`,t(i.p,{children:`The Zig core owns the frame graph, the lens runtime, the texture and buffer
pools, the perception record, the media handling and the degradation policy.`}),`
`,t(i.p,{children:`The SDKs only own the parts that genuinely differ by platform: opening a
camera, handing over a GPU surface, reaching a hardware codec, and presenting
an API that feels right in that language. If an SDK starts implementing a
feature of its own, that's a bug, because then your app behaves differently
depending on which language you wrote it in.`}),`
`,t(i.h2,{id:`three-things-to-know-before-you-start`,children:t(i.a,{href:`#three-things-to-know-before-you-start`,children:`Three things to know before you start`})}),`
`,t(i.p,{children:`These come up constantly, so they're worth reading first.`}),`
`,t(i.ol,{children:[`
`,t(i.li,{children:[t(i.strong,{children:`Everything happens on one thread.`}),` The engine and its sessions belong to
whichever thread created them. See `,t(i.a,{href:`/docs/concepts/threading`,children:`threads and
lifetimes`}),`.`]}),`
`,t(i.li,{children:[t(i.strong,{children:`Not every build does everything.`}),` A stub build answers every call and
computes nothing, which looks exactly like a camera pointed at a blank wall.
Check the `,t(i.a,{href:`/docs/concepts/capabilities`,children:`capability bits`}),` at startup.`]}),`
`,t(i.li,{children:[t(i.strong,{children:`Frames have a budget.`}),` When the work won't fit, the engine turns things
down in a set order instead of dropping the frame. See
`,t(i.a,{href:`/docs/concepts/degradation`,children:`degradation`}),`.`]}),`
`]})]})}function i(e={}){let{wrapper:i}={...n(),...e.components};return i?t(i,{...e,children:t(r,{...e})}):r(e)}function a(e,t){throw Error(`Expected `+(t?`component`:`object`)+" `"+e+"` to be defined: you likely forgot to import, pass, or provide it.")}export{i as default};
//# sourceMappingURL=docs-CXaAQdIz.js.map