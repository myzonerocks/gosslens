import{f as e}from"./index-ChXJvP0h.js";import{t}from"./jsx-runtime-73cbSzV3.js";import{n}from"./lib-C719NGBq.js";function r(r){let i={a:`a`,code:`code`,h2:`h2`,p:`p`,...n(),...r.components};return t(e,{children:[t(i.p,{children:`Almost every problem anybody reports turns out to be one of these. They're
listed by the symptom you'd actually see.`}),`
`,t(i.h2,{id:`everything-is-empty`,children:t(i.a,{href:`#everything-is-empty`,children:`Everything is empty`})}),`
`,t(i.p,{children:`Every list in the record is empty and the camera is clearly working.`}),`
`,t(i.p,{children:[`Check the capability bits first. A stub build answers every call and perceives
nothing, and it looks exactly like a camera pointed at a blank wall. See
`,t(i.a,{href:`/docs/concepts/capabilities`,children:`capabilities`}),`.`]}),`
`,t(i.h2,{id:`it-worked-then-it-stopped-with-no-error`,children:t(i.a,{href:`#it-worked-then-it-stopped-with-no-error`,children:`It worked, then it stopped, with no error`})}),`
`,t(i.p,{children:[`Calls still return `,t(i.code,{children:`GOSS_OK`}),` and nothing updates.`]}),`
`,t(i.p,{children:[`This is nearly always the thread rule. Something is calling the engine from a
different thread than the one that created it, usually a finaliser or a resumed
async continuation. See `,t(i.a,{href:`/docs/concepts/threading`,children:`threads and lifetimes`}),`.`]}),`
`,t(i.h2,{id:`submits-start-failing-under-load`,children:t(i.a,{href:`#submits-start-failing-under-load`,children:`Submits start failing under load`})}),`
`,t(i.p,{children:[t(i.code,{children:`GOSS_ERROR_POOL_EXHAUSTED`}),` after a period of normal running.`]}),`
`,t(i.p,{children:`You're holding frames longer than you think. Release them sooner and apply
backpressure instead of raising the capacity.`}),`
`,t(i.h2,{id:`the-numbers-are-plausible-but-wrong`,children:t(i.a,{href:`#the-numbers-are-plausible-but-wrong`,children:`The numbers are plausible but wrong`})}),`
`,t(i.p,{children:`Landmarks sit near the right places and drift, or a confidence is always the
same odd value.`}),`
`,t(i.p,{children:[`In a hand-written binding this is a struct layout disagreement: you're reading
a field at the wrong offset and landing on a number that happens to look
believable. Assert your offsets against the engine's, and compare a record
field by field against the C binding. See `,t(i.a,{href:`/docs/binding/conformance`,children:`proving a
binding`}),`.`]}),`
`,t(i.h2,{id:`it-refuses-to-start`,children:t(i.a,{href:`#it-refuses-to-start`,children:`It refuses to start`})}),`
`,t(i.p,{children:[t(i.code,{children:`GOSS_ERROR_ABI_MISMATCH`}),` at creation.`]}),`
`,t(i.p,{children:`Your binding and the library are from different ABI majors, and this is working
as intended. Match them. There's no shim, and continuing would mean reading the
wrong bytes at the wrong offsets.`}),`
`,t(i.h2,{id:`no-drawing-but-perception-works`,children:t(i.a,{href:`#no-drawing-but-perception-works`,children:`No drawing, but perception works`})}),`
`,t(i.p,{children:`The record arrives and nothing appears on screen.`}),`
`,t(i.p,{children:[`Either no lens is active, or this build has no renderer. A session without a
lens still perceives, because the lens is the part that draws. If you do have
one active, check for `,t(i.code,{children:`GOSS_ERROR_RENDERER_UNAVAILABLE`}),` when you initialise.`]}),`
`,t(i.h2,{id:`the-phone-gets-hot`,children:t(i.a,{href:`#the-phone-gets-hot`,children:`The phone gets hot`})}),`
`,t(i.p,{children:`Sustained use heats the device and the frame rate sags.`}),`
`,t(i.p,{children:`Look at the budget first. One that fills the whole frame interval leaves
nothing for the compositor and keeps every core busy. Then look for per-frame
allocation in the binding, which is the next most common cause and the easiest
to miss.`}),`
`,t(i.h2,{id:`the-first-frame-is-slow`,children:t(i.a,{href:`#the-first-frame-is-slow`,children:`The first frame is slow`})}),`
`,t(i.p,{children:`Everything is fast except the beginning.`}),`
`,t(i.p,{children:`Something is getting built on first use. Create the engine and the session
before the user needs them, not on the frame that needs them.`}),`
`,t(i.h2,{id:`asking-for-help`,children:t(i.a,{href:`#asking-for-help`,children:`Asking for help`})}),`
`,t(i.p,{children:`Include the ABI version your binding was built against, the version the library
reports, the capability bitfield and the status code. Those four lines answer
most questions before anyone has to reproduce anything.`})]})}function i(e={}){let{wrapper:i}={...n(),...e.components};return i?t(i,{...e,children:t(r,{...e})}):r(e)}export{i as default};
//# sourceMappingURL=troubleshooting-RlGdcWaN.js.map