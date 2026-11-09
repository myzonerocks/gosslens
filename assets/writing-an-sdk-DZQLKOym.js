import{f as e}from"./index-ChXJvP0h.js";import{t}from"./jsx-runtime-73cbSzV3.js";import{n}from"./lib-C719NGBq.js";function r(r){let i={a:`a`,code:`code`,h2:`h2`,li:`li`,p:`p`,pre:`pre`,span:`span`,ul:`ul`,...n(),...r.components},{Note:o,Warning:s}=i;return o||a(`Note`,!0),s||a(`Warning`,!0),t(e,{children:[t(i.p,{children:`The shipped SDKs are thin. Every one of them opens the same header, calls the
same symbols in the same order, and adds nothing the core could have done
itself. That is deliberate: it means a binding for a language nobody has
written yet is a known quantity rather than a research project.`}),`
`,t(i.p,{children:`This page is the whole job. Work through it in order and the result will behave
like the SDKs that ship with the engine, because it will be doing the same
things they do.`}),`
`,t(i.h2,{id:`what-you-are-binding-to`,children:t(i.a,{href:`#what-you-are-binding-to`,children:`What you are binding to`})}),`
`,t(i.p,{children:[`One header, `,t(i.code,{children:`gosslens.h`}),`. It is C99 and includes nothing beyond `,t(i.code,{children:`stdint.h`}),`,
`,t(i.code,{children:`stddef.h`}),` and `,t(i.code,{children:`stdbool.h`}),`, so any language with a C foreign function interface
can reach it without a C++ runtime, exceptions, or a build of its own.`]}),`
`,t(i.p,{children:`Everything that crosses the boundary is one of three things: an opaque handle,
a plain-data descriptor with a fixed layout, or a status code. There is no
inheritance, no callback into your allocator, no ownership you did not ask for.`}),`
`,t(o,{children:t(i.p,{children:[`If your language can call `,t(i.code,{children:`dlopen`}),` and read a struct field at a known offset,
it can host the engine. Nothing further is required of it.`]})}),`
`,t(i.h2,{id:`step-one-check-the-version-and-refuse`,children:t(i.a,{href:`#step-one-check-the-version-and-refuse`,children:`Step one: check the version, and refuse`})}),`
`,t(i.p,{children:[t(i.code,{children:`goss_abi_version`}),` returns a single `,t(i.code,{children:`uint32_t`}),`: the major in the high sixteen
bits, the minor in the low sixteen. It is safe from any thread and must be the
first call your binding makes.`]}),`
`,t(e,{children:t(i.pre,{className:`shiki shiki-themes vitesse-light vitesse-dark`,style:{"--shiki-light":`#393a34`,"--shiki-dark":`#dbd7caee`,"--shiki-light-bg":`#ffffff`,"--shiki-dark-bg":`#121212`},tabIndex:`0`,children:t(i.code,{children:[t(i.span,{className:`line`,children:[t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:`uint32_t`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:` version `}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`=`}),t(i.span,{style:{"--shiki-light":`#59873A`,"--shiki-dark":`#80A665`},children:` goss_abi_version`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`();`})]}),`
`,t(i.span,{className:`line`,children:[t(i.span,{style:{"--shiki-light":`#1E754F`,"--shiki-dark":`#4D9375`},children:`if`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:` ((`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:`version `}),t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:`>>`}),t(i.span,{style:{"--shiki-light":`#2F798A`,"--shiki-dark":`#4C9A91`},children:` 16`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`)`}),t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:` !=`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:` GOSS_ABI_MAJOR`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`)`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:` {`})]}),`
`,t(i.span,{className:`line`,children:t(i.span,{style:{"--shiki-light":`#A0ADA0`,"--shiki-dark":`#758575DD`},children:`    /* Refuse. Do not continue, do not degrade, do not call anything else. */`})}),`
`,t(i.span,{className:`line`,children:[t(i.span,{style:{"--shiki-light":`#1E754F`,"--shiki-dark":`#4D9375`},children:`    return`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:` GOSS_ERROR_ABI_MISMATCH`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`;`})]}),`
`,t(i.span,{className:`line`,children:t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`}`})})]})})}),`
`,t(i.p,{children:`A major mismatch means the layouts your binding was generated against are not
the layouts the library has. Continuing reads the wrong bytes at the wrong
offsets and the failure surfaces somewhere unrelated, hours later.`}),`
`,t(i.p,{children:`The minor moves whenever an operation is added or a struct grows a field. A
higher minor than you were built against is safe: the symbols you know are
still where they were. A lower minor means the library predates a call you may
make, so look up anything optional before you rely on it.`}),`
`,t(i.p,{children:[t(i.code,{children:`goss_abi_check`}),` does the same comparison inside the library and returns a
status, which is the easier call to wire into a binding that already has error
plumbing.`]}),`
`,t(i.h2,{id:`step-two-ask-what-the-build-can-do`,children:t(i.a,{href:`#step-two-ask-what-the-build-can-do`,children:`Step two: ask what the build can do`})}),`
`,t(i.p,{children:`Two libraries can share a filename, a version and a symbol table, and still
differ in what they actually compute. A stub build answers every call and does
no real work, which is exactly what a continuous integration machine with no
camera wants and exactly what an application must not ship against silently.`}),`
`,t(i.p,{children:[t(i.code,{children:`goss_capabilities`}),` returns a bitfield. Read it once, keep it, and gate every
optional path on it.`]}),`
`,t(e,{children:t(i.pre,{className:`shiki shiki-themes vitesse-light vitesse-dark`,style:{"--shiki-light":`#393a34`,"--shiki-dark":`#dbd7caee`,"--shiki-light-bg":`#ffffff`,"--shiki-dark-bg":`#121212`},tabIndex:`0`,children:t(i.code,{children:[t(i.span,{className:`line`,children:[t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:`uint64_t`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:` caps `}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`=`}),t(i.span,{style:{"--shiki-light":`#59873A`,"--shiki-dark":`#80A665`},children:` goss_capabilities`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`();`})]}),`
`,t(i.span,{className:`line`,children:[t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:`bool`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:` can_track `}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`=`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:` (`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:`caps `}),t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:`&`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:` GOSS_CAP_TRACKING`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`)`}),t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:` !=`}),t(i.span,{style:{"--shiki-light":`#2F798A`,"--shiki-dark":`#4C9A91`},children:` 0`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`;`})]}),`
`,t(i.span,{className:`line`,children:[t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:`bool`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:` can_segment `}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`=`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:` (`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:`caps `}),t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:`&`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:` GOSS_CAP_SEGMENTATION`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`)`}),t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:` !=`}),t(i.span,{style:{"--shiki-light":`#2F798A`,"--shiki-dark":`#4C9A91`},children:` 0`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`;`})]})]})})}),`
`,t(i.p,{children:`Surface the bitfield to your users rather than hiding it. An application that
can see the engine has no tracking compiled in can say so; one that cannot see
it reports a camera bug instead.`}),`
`,t(i.h2,{id:`step-three-the-lifecycle-and-who-owns-what`,children:t(i.a,{href:`#step-three-the-lifecycle-and-who-owns-what`,children:`Step three: the lifecycle, and who owns what`})}),`
`,t(i.p,{children:[`Ownership is in the name and there are no exceptions to it. Every `,t(i.code,{children:`create`}),` has
a `,t(i.code,{children:`destroy`}),`. Every `,t(i.code,{children:`acquire`}),` has a `,t(i.code,{children:`release`}),`. A function that can fail returns
`,t(i.code,{children:`goss_status`}),`; there is no errno and nothing throws.`]}),`
`,t(e,{children:t(i.pre,{className:`shiki shiki-themes vitesse-light vitesse-dark`,style:{"--shiki-light":`#393a34`,"--shiki-dark":`#dbd7caee`,"--shiki-light-bg":`#ffffff`,"--shiki-dark-bg":`#121212`},tabIndex:`0`,children:t(i.code,{children:[t(i.span,{className:`line`,children:[t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:`goss_engine `}),t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:`*`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:`engine `}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`=`}),t(i.span,{style:{"--shiki-light":`#1E754F`,"--shiki-dark":`#4D9375`},children:` NULL`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`;`})]}),`
`,t(i.span,{className:`line`,children:[t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:`goss_engine_config engine_config `}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`=`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:` {`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:` .texture_pool_capacity `}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`=`}),t(i.span,{style:{"--shiki-light":`#2F798A`,"--shiki-dark":`#4C9A91`},children:` 8`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:` };`})]}),`
`,t(i.span,{className:`line`,children:[t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:`goss_status status `}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`=`}),t(i.span,{style:{"--shiki-light":`#59873A`,"--shiki-dark":`#80A665`},children:` goss_engine_create`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`(`}),t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:`&`}),t(i.span,{style:{"--shiki-light":`#B07D48`,"--shiki-dark":`#BD976A`},children:`engine_config`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`,`}),t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:` &`}),t(i.span,{style:{"--shiki-light":`#B07D48`,"--shiki-dark":`#BD976A`},children:`engine`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`);`})]}),`
`,t(i.span,{className:`line`,children:[t(i.span,{style:{"--shiki-light":`#1E754F`,"--shiki-dark":`#4D9375`},children:`if`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:` (`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:`status `}),t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:`!=`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:` GOSS_OK`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`)`}),t(i.span,{style:{"--shiki-light":`#1E754F`,"--shiki-dark":`#4D9375`},children:` return`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:` status`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`;`})]}),`
`,t(i.span,{className:`line`}),`
`,t(i.span,{className:`line`,children:[t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:`goss_session `}),t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:`*`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:`session `}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`=`}),t(i.span,{style:{"--shiki-light":`#1E754F`,"--shiki-dark":`#4D9375`},children:` NULL`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`;`})]}),`
`,t(i.span,{className:`line`,children:[t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:`goss_session_config session_config `}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`=`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:` {`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:` .frame_budget_us `}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`=`}),t(i.span,{style:{"--shiki-light":`#2F798A`,"--shiki-dark":`#4C9A91`},children:` 8000`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:` };`})]}),`
`,t(i.span,{className:`line`,children:[t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:`status `}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`=`}),t(i.span,{style:{"--shiki-light":`#59873A`,"--shiki-dark":`#80A665`},children:` goss_session_create`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`(`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:`engine`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`,`}),t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:` &`}),t(i.span,{style:{"--shiki-light":`#B07D48`,"--shiki-dark":`#BD976A`},children:`session_config`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`,`}),t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:` &`}),t(i.span,{style:{"--shiki-light":`#B07D48`,"--shiki-dark":`#BD976A`},children:`session`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`);`})]})]})})}),`
`,t(i.p,{children:`A session holds its engine. Destroy sessions before the engine they came from,
and make that structural rather than documented: in a language with
deterministic destruction, have the session object keep a strong reference to
the engine object, so the engine cannot be collected out from under a session
that is still drawing.`}),`
`,t(i.p,{children:`Zero means "the engine chooses" in both configs. Pass zeroed structs until you
have measured a reason not to.`}),`
`,t(i.h2,{id:`step-four-the-thread-rule`,children:t(i.a,{href:`#step-four-the-thread-rule`,children:`Step four: the thread rule`})}),`
`,t(i.p,{children:[`An engine and its sessions are confined to the thread that created them, called
the graph thread. A function is callable from another thread only when the
header says it is any-thread, as `,t(i.code,{children:`goss_abi_version`}),` does.`]}),`
`,t(i.p,{children:[`This is the rule most new bindings get wrong, because most languages make it
easy to break. A garbage collector that finalises on its own thread will call
`,t(i.code,{children:`destroy`}),` from the wrong one. An async runtime that resumes a continuation
wherever a worker is free will submit a frame from the wrong one.`]}),`
`,t(i.p,{children:`Pin it explicitly:`}),`
`,t(i.ul,{children:[`
`,t(i.li,{children:`Give the binding one owned thread, or require the caller to name theirs.`}),`
`,t(i.li,{children:`Record the thread identity at creation and assert it on every call in debug
builds. The assertion costs nothing in release and saves whole afternoons.`}),`
`,t(i.li,{children:`Never let a finaliser call into the engine. Have it post the destroy to the
graph thread instead.`}),`
`]}),`
`,t(s,{children:t(i.p,{children:`A call from the wrong thread does not reliably crash. It corrupts the pool's
bookkeeping and the symptom appears several frames later as a texture that
belongs to somebody else.`})}),`
`,t(i.h2,{id:`step-five-structs-by-layout-and-nothing-else`,children:t(i.a,{href:`#step-five-structs-by-layout-and-nothing-else`,children:`Step five: structs, by layout and nothing else`})}),`
`,t(i.p,{children:[`Descriptors are `,t(i.code,{children:`extern`}),` structs with explicit padding, and their layout is
static-asserted in the engine's own tests. Your binding has to agree with that
layout byte for byte.`]}),`
`,t(i.p,{children:`Generate the declarations rather than typing them. Every shipped SDK derives
its structs from the header, which is why none of them has ever disagreed with
it. If your language has no generator, write a test that compares your computed
offsets against the sizes the engine reports, and run it in continuous
integration rather than once.`}),`
`,t(i.p,{children:`Vectors cross by pointer. A position, a quaternion, a matrix or a colour is
passed as a pointer to a fixed-size array, never spread into separate float
parameters. This is an ABI hazard rather than a style preference: past the
eighth float argument the x86_64 calling convention spills to the stack, and a
caller and callee compiled by different toolchains can disagree about that
layout. Passing the aggregate keeps every scalar in a register and marshals
identically everywhere.`}),`
`,t(i.p,{children:`A struct only ever grows at its end, behind a size field. Read the size the
engine reports before touching a field your build added.`}),`
`,t(i.h2,{id:`step-six-frames-without-copying`,children:t(i.a,{href:`#step-six-frames-without-copying`,children:`Step six: frames, without copying`})}),`
`,t(i.p,{children:`The whole point of the engine is that a camera frame reaches it without a
round trip through your language's heap. How that works is platform shaped, and
your binding should expose the platform path first and the copy path second:`}),`
`,t(i.ul,{children:[`
`,t(i.li,{children:`Where the platform has a hardware buffer or a shared texture, import it and
submit the handle.`}),`
`,t(i.li,{children:`Where it does not, submit the planes and let the engine stage them.`}),`
`,t(i.li,{children:`Offer a copying call for correctness while bringing a platform up, and mark
it as the slow path in your own documentation so nobody ships on it.`}),`
`]}),`
`,t(i.p,{children:`Reuse the buffers you allocate. A per-frame allocation in a binding is a
per-frame allocation in the product, and it is the first thing to show up in a
thermal profile.`}),`
`,t(i.h2,{id:`step-seven-reading-the-record-back`,children:t(i.a,{href:`#step-seven-reading-the-record-back`,children:`Step seven: reading the record back`})}),`
`,t(i.p,{children:`Perception comes back as a snapshot the caller asks for, not as a callback the
engine fires. Ask once per frame, after submitting, and hand your users an
immutable value.`}),`
`,t(i.p,{children:`A JSON form exists and is the right first move for a new binding: it is stable,
it is easy to assert against, and it gets a working end-to-end path in an
afternoon. Move to the packed form once the shape is proven and you want the
allocation back.`}),`
`,t(i.h2,{id:`step-eight-events-drained-not-polled`,children:t(i.a,{href:`#step-eight-events-drained-not-polled`,children:`Step eight: events, drained not polled`})}),`
`,t(i.p,{children:`The engine keeps a ring of events. A caller drains it and is told how many were
missed since the last drain. Surface that number rather than swallowing it: a
missed count that climbs is the clearest early signal that the host is not
keeping up, and an application that cannot see it has no way to react.`}),`
`,t(i.p,{children:`Do not wrap the drain in a thread that spins. Drain it on the frame you already
have.`}),`
`,t(i.h2,{id:`step-nine-prove-it-the-same-way-the-others-are-proved`,children:t(i.a,{href:`#step-nine-prove-it-the-same-way-the-others-are-proved`,children:`Step nine: prove it, the same way the others are proved`})}),`
`,t(i.p,{children:[`A binding is not finished when it runs. It is finished when it agrees with the
other bindings about what the engine said. Run the same program through your
binding and through the C one, and compare the records field by field. See
`,t(i.a,{href:`/docs/binding/conformance`,children:`proving a binding`}),` for what that suite looks like
and what it has to cover.`]}),`
`,t(i.h2,{id:`the-shape-of-a-good-binding`,children:t(i.a,{href:`#the-shape-of-a-good-binding`,children:`The shape of a good binding`})}),`
`,t(i.p,{children:`Everything above comes down to one rule: the binding translates and does
nothing else.`}),`
`,t(i.p,{children:`If your binding smooths a jittery landmark, caches a record, retries a failed
call, or decides which capability to use, then the behaviour of the product now
depends on which language the application happens to be written in. That is the
failure this architecture exists to prevent. Features belong in the core, where
every caller gets them at once. A binding that needed a feature has found a
hole in the core, and the fix is to say so rather than to patch it locally.`})]})}function i(e={}){let{wrapper:i}={...n(),...e.components};return i?t(i,{...e,children:t(r,{...e})}):r(e)}function a(e,t){throw Error(`Expected `+(t?`component`:`object`)+" `"+e+"` to be defined: you likely forgot to import, pass, or provide it.")}export{i as default};
//# sourceMappingURL=writing-an-sdk-DZQLKOym.js.map