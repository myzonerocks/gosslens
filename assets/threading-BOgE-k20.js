import{f as e}from"./index-ChXJvP0h.js";import{t}from"./jsx-runtime-73cbSzV3.js";import{n}from"./lib-C719NGBq.js";function r(r){let i={a:`a`,code:`code`,h2:`h2`,p:`p`,strong:`strong`,...n(),...r.components},{Warning:o}=i;return o||a(`Warning`,!0),t(e,{children:[t(i.p,{children:`There's one threading rule, and it's worth more attention than its length
suggests, because breaking it doesn't reliably crash.`}),`
`,t(i.h2,{id:`one-thread-owns-everything`,children:t(i.a,{href:`#one-thread-owns-everything`,children:`One thread owns everything`})}),`
`,t(i.p,{children:`An engine and every session you make from it belong to the thread that created
them. We call that the graph thread. Calling from anywhere else is undefined
unless the header marks a function as any-thread.`}),`
`,t(i.p,{children:`There's no lock inside the boundary making this safe for you. The engine is
fast partly because it doesn't pay for one on every call, and this rule is what
that costs.`}),`
`,t(i.h2,{id:`whats-safe-from-anywhere`,children:t(i.a,{href:`#whats-safe-from-anywhere`,children:`What's safe from anywhere`})}),`
`,t(i.p,{children:[t(i.code,{children:`goss_abi_version`}),` is, and it has to be, because a binding calls it before it's
decided anything at all, including which thread will own the engine. A few
other calls are marked the same way in the header. Treat anything unmarked as
confined.`]}),`
`,t(i.h2,{id:`where-this-actually-goes-wrong`,children:t(i.a,{href:`#where-this-actually-goes-wrong`,children:`Where this actually goes wrong`})}),`
`,t(i.p,{children:`Almost nobody calls the engine from a second thread on purpose. It happens two
ways.`}),`
`,t(i.p,{children:[t(i.strong,{children:`A finaliser.`}),` Your garbage collector runs on its own thread, and the destroy
it triggers arrives from there. Every binding has to post that destroy back to
the graph thread instead of letting the collector make the call.`]}),`
`,t(i.p,{children:[t(i.strong,{children:`A resumed continuation.`}),` An async runtime resumes work on whichever worker
is free. Code that reads perfectly, submitting a frame after awaiting the
camera, can run that submit on a different thread each time.`]}),`
`,t(i.p,{children:`Both look the same from outside: things work for a while, then the pool
bookkeeping stops adding up, then a texture gets handed to the wrong caller a
few frames later.`}),`
`,t(o,{children:t(i.p,{children:`Assert the thread identity in your debug builds. It costs nothing in release,
and this is not a bug you want to find by staring at a frame counter.`})}),`
`,t(i.h2,{id:`lifetimes`,children:t(i.a,{href:`#lifetimes`,children:`Lifetimes`})}),`
`,t(i.p,{children:`A session holds onto its engine, so destroy sessions first and the engine
after.`}),`
`,t(i.p,{children:`Make that structural rather than something you remember. In a language with
deterministic destruction, have the session object hold a strong reference to
the engine object, so the engine can't be released while a session is still
drawing. Without that, keep the engine alive explicitly for as long as any
session exists.`}),`
`,t(i.p,{children:[`Every `,t(i.code,{children:`create`}),` has exactly one `,t(i.code,{children:`destroy`}),`. Calling it twice has to be safe in
your binding even though it isn't at the boundary, which is why each of our
SDKs keeps a flag and lets the explicit call and the automatic one share it.`]}),`
`,t(i.h2,{id:`frames`,children:t(i.a,{href:`#frames`,children:`Frames`})}),`
`,t(i.p,{children:[`A frame you submit belongs to the engine until it says otherwise. Holding onto
one past its release is how a pool runs out, and `,t(i.code,{children:`GOSS_ERROR_POOL_EXHAUSTED`}),` is
the engine telling you that's what happened.`]}),`
`,t(i.p,{children:`The right response is backpressure: stop pulling frames from the camera until
the engine has caught up. Raising the pool capacity just moves the problem to a
bigger number of frames and makes the eventual stall longer.`})]})}function i(e={}){let{wrapper:i}={...n(),...e.components};return i?t(i,{...e,children:t(r,{...e})}):r(e)}function a(e,t){throw Error(`Expected `+(t?`component`:`object`)+" `"+e+"` to be defined: you likely forgot to import, pass, or provide it.")}export{i as default};
//# sourceMappingURL=threading-BOgE-k20.js.map