import{f as e}from"./index-ChXJvP0h.js";import{t}from"./jsx-runtime-73cbSzV3.js";import{n}from"./lib-C719NGBq.js";function r(r){let i={a:`a`,code:`code`,h2:`h2`,p:`p`,pre:`pre`,span:`span`,...n(),...r.components};return t(e,{children:[t(i.p,{children:[t(i.code,{children:`gosslens.h`}),` is the whole public surface. It's C99 and includes nothing beyond
`,t(i.code,{children:`stdint.h`}),`, `,t(i.code,{children:`stddef.h`}),` and `,t(i.code,{children:`stdbool.h`}),`. Every symbol starts with `,t(i.code,{children:`goss_`}),`.`]}),`
`,t(i.h2,{id:`handles-are-opaque`,children:t(i.a,{href:`#handles-are-opaque`,children:`Handles are opaque`})}),`
`,t(i.p,{children:[t(i.code,{children:`goss_engine`}),` and `,t(i.code,{children:`goss_session`}),` are pointers to types you never see inside,
and they're the only two handles that cross. Everything else lives behind the
session, which is why there's no third lifetime for a binding to get wrong.`]}),`
`,t(i.p,{children:`The only structures that cross are plain-data descriptors, and their layouts
are static-asserted in the engine's tests and documented field by field in the
header.`}),`
`,t(i.h2,{id:`ownership-is-in-the-name`,children:t(i.a,{href:`#ownership-is-in-the-name`,children:`Ownership is in the name`})}),`
`,t(e,{children:t(i.pre,{className:`shiki shiki-themes vitesse-light vitesse-dark`,style:{"--shiki-light":`#393a34`,"--shiki-dark":`#dbd7caee`,"--shiki-light-bg":`#ffffff`,"--shiki-dark-bg":`#121212`},tabIndex:`0`,children:t(i.code,{children:[t(i.span,{className:`line`,children:[t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:`goss_status `}),t(i.span,{style:{"--shiki-light":`#59873A`,"--shiki-dark":`#80A665`},children:`goss_session_create`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`(`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:`goss_engine `}),t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:`*`}),t(i.span,{style:{"--shiki-light":`#B07D48`,"--shiki-dark":`#BD976A`},children:`engine`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`,`}),t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:` const`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:` goss_session_config `}),t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:`*`}),t(i.span,{style:{"--shiki-light":`#B07D48`,"--shiki-dark":`#BD976A`},children:`config`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`,`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:` goss_session `}),t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:`**`}),t(i.span,{style:{"--shiki-light":`#B07D48`,"--shiki-dark":`#BD976A`},children:`out_session`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`);`})]}),`
`,t(i.span,{className:`line`,children:[t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:`void`}),t(i.span,{style:{"--shiki-light":`#59873A`,"--shiki-dark":`#80A665`},children:`        goss_session_destroy`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`(`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:`goss_session `}),t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:`*`}),t(i.span,{style:{"--shiki-light":`#B07D48`,"--shiki-dark":`#BD976A`},children:`session`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`);`})]})]})})}),`
`,t(i.p,{children:[`Every `,t(i.code,{children:`create`}),` has a `,t(i.code,{children:`destroy`}),` and every `,t(i.code,{children:`acquire`}),` has a `,t(i.code,{children:`release`}),`. Anything
that can fail returns `,t(i.code,{children:`goss_status`}),`. There's no errno, and no exception crosses
the boundary, because every C++ shim catches at its own edge and turns it into
a status.`]}),`
`,t(i.h2,{id:`vectors-cross-by-pointer`,children:t(i.a,{href:`#vectors-cross-by-pointer`,children:`Vectors cross by pointer`})}),`
`,t(i.p,{children:`A position, a quaternion, a matrix or a colour goes across as a pointer to a
fixed-size array, never spread out into separate float parameters.`}),`
`,t(i.p,{children:`That's an ABI hazard, not a style preference. Past the eighth float argument
the x86_64 calling convention starts spilling to the stack, and a caller and
callee built by different toolchains can disagree about that layout. Passing
the aggregate keeps every scalar in a register and marshals the same way
everywhere.`}),`
`,t(i.h2,{id:`versioned-and-checked-first`,children:t(i.a,{href:`#versioned-and-checked-first`,children:`Versioned, and checked first`})}),`
`,t(e,{children:t(i.pre,{className:`shiki shiki-themes vitesse-light vitesse-dark`,style:{"--shiki-light":`#393a34`,"--shiki-dark":`#dbd7caee`,"--shiki-light-bg":`#ffffff`,"--shiki-dark-bg":`#121212`},tabIndex:`0`,children:t(i.code,{children:t(i.span,{className:`line`,children:[t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:`uint32_t`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:` v `}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`=`}),t(i.span,{style:{"--shiki-light":`#59873A`,"--shiki-dark":`#80A665`},children:` goss_abi_version`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`();`}),t(i.span,{style:{"--shiki-light":`#A0ADA0`,"--shiki-dark":`#758575DD`},children:`  // high 16 bits major, low 16 minor`})]})})})}),`
`,t(i.p,{children:`The minor comes from the operation list plus the field count of every struct
that crosses, so adding a field to a record moves the number on its own and
nobody has to remember to bump it. An SDK compares the major and refuses to run
if it doesn't match.`}),`
`,t(i.p,{children:`There's no compatibility shim, and you don't want one: continuing past a major
mismatch means reading the wrong bytes at the wrong offsets, and that usually
produces numbers that look believable.`})]})}function i(e={}){let{wrapper:i}={...n(),...e.components};return i?t(i,{...e,children:t(r,{...e})}):r(e)}export{i as default};
//# sourceMappingURL=abi-DsZnDD6B.js.map