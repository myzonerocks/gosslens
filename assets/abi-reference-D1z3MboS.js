import{f as e}from"./index-ChXJvP0h.js";import{t}from"./jsx-runtime-73cbSzV3.js";import{n}from"./lib-C719NGBq.js";function r(r){let i={a:`a`,code:`code`,h2:`h2`,li:`li`,p:`p`,pre:`pre`,span:`span`,table:`table`,tbody:`tbody`,td:`td`,th:`th`,thead:`thead`,tr:`tr`,ul:`ul`,...n(),...r.components};return t(e,{children:[t(i.p,{children:`This page is the contract. It describes what the boundary guarantees, what it
does not, and what changes between releases.`}),`
`,t(i.h2,{id:`versioning`,children:t(i.a,{href:`#versioning`,children:`Versioning`})}),`
`,t(e,{children:t(i.pre,{className:`shiki shiki-themes vitesse-light vitesse-dark`,style:{"--shiki-light":`#393a34`,"--shiki-dark":`#dbd7caee`,"--shiki-light-bg":`#ffffff`,"--shiki-dark-bg":`#121212`},tabIndex:`0`,children:t(i.code,{children:[t(i.span,{className:`line`,children:[t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`#`}),t(i.span,{style:{"--shiki-light":`#1E754F`,"--shiki-dark":`#4D9375`},children:`define`}),t(i.span,{style:{"--shiki-light":`#59873A`,"--shiki-dark":`#80A665`},children:` GOSS_ABI_MAJOR`}),t(i.span,{style:{"--shiki-light":`#2F798A`,"--shiki-dark":`#4C9A91`},children:` 0`}),t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:`u`})]}),`
`,t(i.span,{className:`line`,children:[t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`#`}),t(i.span,{style:{"--shiki-light":`#1E754F`,"--shiki-dark":`#4D9375`},children:`define`}),t(i.span,{style:{"--shiki-light":`#59873A`,"--shiki-dark":`#80A665`},children:` GOSS_ABI_MINOR`}),t(i.span,{style:{"--shiki-light":`#2F798A`,"--shiki-dark":`#4C9A91`},children:` 176`}),t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:`u`})]}),`
`,t(i.span,{className:`line`,children:[t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`#`}),t(i.span,{style:{"--shiki-light":`#1E754F`,"--shiki-dark":`#4D9375`},children:`define`}),t(i.span,{style:{"--shiki-light":`#59873A`,"--shiki-dark":`#80A665`},children:` GOSS_ABI_VERSION`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:` ((`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:`GOSS_ABI_MAJOR `}),t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:`<<`}),t(i.span,{style:{"--shiki-light":`#2F798A`,"--shiki-dark":`#4C9A91`},children:` 16`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`)`}),t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:` |`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:` GOSS_ABI_MINOR`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`)`})]}),`
`,t(i.span,{className:`line`}),`
`,t(i.span,{className:`line`,children:[t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:`uint32_t`}),t(i.span,{style:{"--shiki-light":`#59873A`,"--shiki-dark":`#80A665`},children:` goss_abi_version`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`(`}),t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:`void`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`);`}),t(i.span,{style:{"--shiki-light":`#A0ADA0`,"--shiki-dark":`#758575DD`},children:`  /* any-thread */`})]})]})})}),`
`,t(i.p,{children:`The major changes only when an existing layout or an existing meaning changes.
Compare it and refuse on a mismatch; there is no compatibility shim and asking
for one is asking to read the wrong bytes.`}),`
`,t(i.p,{children:`The minor is derived rather than chosen. It counts the operation list plus the
field count of every struct that crosses, so appending a field to a record
moves the number on its own and nobody has to remember to bump it.`}),`
`,t(i.p,{children:`Build your binding against a header, record the version it was generated from,
and report both at runtime when they differ. A support question answered with
"the library is older than the binding by this many minors" is a question
already solved.`}),`
`,t(i.h2,{id:`status-codes`,children:t(i.a,{href:`#status-codes`,children:`Status codes`})}),`
`,t(i.p,{children:[`Every call that can fail returns `,t(i.code,{children:`goss_status`}),`. Nothing throws, nothing sets
errno, and no exception crosses the boundary, because every internal shim
catches at its own edge and maps to a status.`]}),`
`,t(i.table,{children:[t(i.thead,{children:t(i.tr,{children:[t(i.th,{children:`Code`}),t(i.th,{children:`Meaning`}),t(i.th,{children:`What to do`})]})}),t(i.tbody,{children:[t(i.tr,{children:[t(i.td,{children:t(i.code,{children:`GOSS_OK`})}),t(i.td,{children:`The call did what it said`}),t(i.td,{children:`Continue`})]}),t(i.tr,{children:[t(i.td,{children:t(i.code,{children:`GOSS_ERROR_INVALID_ARGUMENT`})}),t(i.td,{children:`A pointer, size or enum did not make sense`}),t(i.td,{children:`Fix the caller; this is a bug, not a condition`})]}),t(i.tr,{children:[t(i.td,{children:t(i.code,{children:`GOSS_ERROR_OUT_OF_MEMORY`})}),t(i.td,{children:`An allocation failed`}),t(i.td,{children:`Release what you can and retry, or fail the feature`})]}),t(i.tr,{children:[t(i.td,{children:t(i.code,{children:`GOSS_ERROR_POOL_EXHAUSTED`})}),t(i.td,{children:`Every buffer in a pool is still held`}),t(i.td,{children:`Release frames sooner, or raise the pool capacity`})]}),t(i.tr,{children:[t(i.td,{children:t(i.code,{children:`GOSS_ERROR_ABI_MISMATCH`})}),t(i.td,{children:`The caller and the library disagree`}),t(i.td,{children:`Refuse to run`})]}),t(i.tr,{children:[t(i.td,{children:t(i.code,{children:`GOSS_ERROR_RENDERER_UNAVAILABLE`})}),t(i.td,{children:`No usable graphics device`}),t(i.td,{children:`Run without the drawing path, or tell the user`})]}),t(i.tr,{children:[t(i.td,{children:t(i.code,{children:`GOSS_ERROR_UNSUPPORTED`})}),t(i.td,{children:`This build has no such capability`}),t(i.td,{children:`Check the capability bits first`})]})]})]}),`
`,t(i.p,{children:[t(i.code,{children:`GOSS_ERROR_POOL_EXHAUSTED`}),` is the one worth special handling. It almost always
means the application is holding frames longer than it thinks, and the honest
response is backpressure rather than a larger pool.`]}),`
`,t(i.h2,{id:`capability-bits`,children:t(i.a,{href:`#capability-bits`,children:`Capability bits`})}),`
`,t(i.p,{children:[t(i.code,{children:`goss_capabilities`}),` returns a bitfield describing what this build actually
computes. The stub and full libraries share a filename and a version, so this
is the only way to tell them apart before feeding real bytes to an operation.`]}),`
`,t(e,{children:t(i.pre,{className:`shiki shiki-themes vitesse-light vitesse-dark`,style:{"--shiki-light":`#393a34`,"--shiki-dark":`#dbd7caee`,"--shiki-light-bg":`#ffffff`,"--shiki-dark-bg":`#121212`},tabIndex:`0`,children:t(i.code,{children:t(i.span,{className:`line`,children:[t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:`uint64_t`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:` caps `}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`=`}),t(i.span,{style:{"--shiki-light":`#59873A`,"--shiki-dark":`#80A665`},children:` goss_capabilities`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`();`})]})})})}),`
`,t(i.p,{children:[`The bits cover tracking and world tracking, segmentation, machine learning
inference, diffusion, beauty, physics, reconstruction, video textures, photo
capture, recording, audio playback and recording, file access, scripting,
stroke boards and diagnostics. Each is defined in the header as
`,t(i.code,{children:`GOSS_CAP_<NAME>`}),`; read them from there rather than copying a list, because
the list grows.`]}),`
`,t(i.p,{children:`Gate on the bit, not on a platform guess. A build for a phone and a build for
a test machine differ by what was compiled in, not by what the operating system
is called.`}),`
`,t(i.h2,{id:`handles`,children:t(i.a,{href:`#handles`,children:`Handles`})}),`
`,t(e,{children:t(i.pre,{className:`shiki shiki-themes vitesse-light vitesse-dark`,style:{"--shiki-light":`#393a34`,"--shiki-dark":`#dbd7caee`,"--shiki-light-bg":`#ffffff`,"--shiki-dark-bg":`#121212`},tabIndex:`0`,children:t(i.code,{children:[t(i.span,{className:`line`,children:[t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:`goss_engine`}),t(i.span,{style:{"--shiki-light":`#A0ADA0`,"--shiki-dark":`#758575DD`},children:`   /* the library's own state, pools and devices */`})]}),`
`,t(i.span,{className:`line`,children:[t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:`goss_session`}),t(i.span,{style:{"--shiki-light":`#A0ADA0`,"--shiki-dark":`#758575DD`},children:`  /* one stream of frames, with its own budget */`})]})]})})}),`
`,t(i.p,{children:`Two handles cross, and that is the whole set. A lens, a frame and everything
else live behind the session rather than as handles of their own, which is why
there is no third lifetime for a binding to get wrong.`}),`
`,t(i.p,{children:`Each is a pointer to a type the caller never sees inside. They cannot be
copied, compared for ordering, serialised, or constructed by hand. Hold them,
pass them back, and destroy them in the order they were made.`}),`
`,t(i.h2,{id:`layout-rules`,children:t(i.a,{href:`#layout-rules`,children:`Layout rules`})}),`
`,t(i.p,{children:`Descriptors are plain data with fixed layouts that are static-asserted inside
the engine and documented field by field in the header.`}),`
`,t(i.ul,{children:[`
`,t(i.li,{children:[`Structs are `,t(i.code,{children:`extern`}),` with explicit padding. Nothing is packed and nothing is
reordered by the compiler.`]}),`
`,t(i.li,{children:`A field is only ever added at the end of a struct, behind a size field, so a
binding built against an older header reads the prefix it knows.`}),`
`,t(i.li,{children:`Vectors cross by pointer to a fixed-size array, never as loose floats, so a
caller and callee built by different toolchains agree about where every
scalar lives.`}),`
`,t(i.li,{children:`Enums cross as explicit integer types. There is no implementation-defined
enum width at the boundary.`}),`
`]}),`
`,t(i.h2,{id:`threading`,children:t(i.a,{href:`#threading`,children:`Threading`})}),`
`,t(i.p,{children:`An engine and the sessions made from it are confined to the thread that
created them. A function may be called from elsewhere only where the header
says any-thread.`}),`
`,t(i.p,{children:[t(i.code,{children:`goss_abi_version`}),` is any-thread and must be the first call a binding makes.
Treat everything else as confined unless its own comment says otherwise, and
assert the thread identity in debug builds rather than trusting a convention.`]}),`
`,t(i.h2,{id:`memory`,children:t(i.a,{href:`#memory`,children:`Memory`})}),`
`,t(i.p,{children:[t(i.code,{children:`goss_alloc`}),` and `,t(i.code,{children:`goss_free`}),` exist for the cases where the engine hands back a
buffer whose lifetime the caller controls. Free what the engine allocated with
`,t(i.code,{children:`goss_free`}),` and nothing else; your language's allocator did not make it and
cannot release it.`]}),`
`,t(i.p,{children:[`Everything else the engine allocates, the engine owns, and the matching
`,t(i.code,{children:`destroy`}),` or `,t(i.code,{children:`release`}),` is the only correct way to hand it back.`]})]})}function i(e={}){let{wrapper:i}={...n(),...e.components};return i?t(i,{...e,children:t(r,{...e})}):r(e)}export{i as default};
//# sourceMappingURL=abi-reference-D1z3MboS.js.map