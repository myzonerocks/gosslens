import{f as e}from"./index-ChXJvP0h.js";import{t}from"./jsx-runtime-73cbSzV3.js";import{n}from"./lib-C719NGBq.js";function r(r){let i={a:`a`,code:`code`,h2:`h2`,p:`p`,...n(),...r.components};return t(e,{children:[t(i.p,{children:`A binding that runs is not a binding that works. The failures that matter are
quiet: a field read at the wrong offset that happens to hold a plausible
number, a frame released twice that only corrupts the pool under load, a record
that agrees with the C one until the day somebody enables segmentation.`}),`
`,t(i.p,{children:`The suite below is what the shipped SDKs are held to. Run it in continuous
integration, not once by hand.`}),`
`,t(i.h2,{id:`agree-with-the-header`,children:t(i.a,{href:`#agree-with-the-header`,children:`Agree with the header`})}),`
`,t(i.p,{children:[`Generate your struct declarations from `,t(i.code,{children:`gosslens.h`}),`, then test that the
generated ones are still right.`]}),`
`,t(i.p,{children:`For every descriptor that crosses, assert the total size and the offset of
every field against the values the engine reports. A test that only checks the
fields you currently read will pass on the day a field is inserted and fail
somewhere far away on the day after.`}),`
`,t(i.h2,{id:`agree-with-another-binding`,children:t(i.a,{href:`#agree-with-another-binding`,children:`Agree with another binding`})}),`
`,t(i.p,{children:`Take one program. Submit the same frames through your binding and through the
C one, and compare the records field by field, including the fields your
binding does not expose yet.`}),`
`,t(i.p,{children:`This is the test that catches a wrong offset, a sign error, a byte order
assumption, and a float that was quietly truncated on the way through. Nothing
else catches all four.`}),`
`,t(i.h2,{id:`refuse-the-wrong-library`,children:t(i.a,{href:`#refuse-the-wrong-library`,children:`Refuse the wrong library`})}),`
`,t(i.p,{children:`Point the binding at a library with a different ABI major and assert that it
refuses before it creates anything. Then point it at a stub build and assert
that every optional path is skipped rather than silently returning zeroes.`}),`
`,t(i.p,{children:`Both cases are easy to get wrong in a way that only shows up for a user with
an unusual install.`}),`
`,t(i.h2,{id:`hold-the-thread-rule`,children:t(i.a,{href:`#hold-the-thread-rule`,children:`Hold the thread rule`})}),`
`,t(i.p,{children:`Call into the engine from a second thread and assert that your debug build
catches it. If it does not, the rule is documented rather than enforced, and a
future maintainer of your binding will break it without knowing.`}),`
`,t(i.p,{children:`Then test the case that actually happens in production: let an object become
unreachable and confirm the destroy runs on the graph thread rather than on
whatever thread the collector happened to use.`}),`
`,t(i.h2,{id:`leak-nothing-twice`,children:t(i.a,{href:`#leak-nothing-twice`,children:`Leak nothing, twice`})}),`
`,t(i.p,{children:`Create and destroy engines and sessions in a loop and assert the process size
is flat at the end. Run the same loop with failures injected at every create,
so the error paths are exercised rather than assumed.`}),`
`,t(i.p,{children:`Then do it again, destroying in the wrong order, and assert that the binding
prevents it structurally rather than crashing.`}),`
`,t(i.h2,{id:`survive-exhaustion`,children:t(i.a,{href:`#survive-exhaustion`,children:`Survive exhaustion`})}),`
`,t(i.p,{children:[`Hold every frame in the pool and assert that the next submit returns
`,t(i.code,{children:`GOSS_ERROR_POOL_EXHAUSTED`}),` and that your binding surfaces it as backpressure
rather than as a failure. Then release and assert the stream recovers without
a restart.`]}),`
`,t(i.h2,{id:`report-what-was-missed`,children:t(i.a,{href:`#report-what-was-missed`,children:`Report what was missed`})}),`
`,t(i.p,{children:`Drain events slower than the engine produces them and assert that the missed
count your binding reports is the engine's number rather than zero. A binding
that swallows it has removed the only signal the application had.`}),`
`,t(i.h2,{id:`what-a-pass-means`,children:t(i.a,{href:`#what-a-pass-means`,children:`What a pass means`})}),`
`,t(i.p,{children:`A binding that passes all of the above behaves like the ones that ship, which
is the only claim worth making about it. It does not mean the binding is
idiomatic, documented or pleasant, and those are worth doing too. It means an
application written against it will see what the engine saw.`})]})}function i(e={}){let{wrapper:i}={...n(),...e.components};return i?t(i,{...e,children:t(r,{...e})}):r(e)}export{i as default};
//# sourceMappingURL=conformance-CiBsAjZ6.js.map