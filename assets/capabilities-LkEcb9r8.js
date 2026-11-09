import{f as e}from"./index-ChXJvP0h.js";import{t}from"./jsx-runtime-73cbSzV3.js";import{n}from"./lib-C719NGBq.js";function r(r){let i={a:`a`,code:`code`,h2:`h2`,p:`p`,pre:`pre`,span:`span`,strong:`strong`,...n(),...r.components};return t(e,{children:[t(i.p,{children:`The engine ships in more than one shape. A full build computes what it says it
does. A stub build answers every call, hands back well-formed empty results,
and does no actual work.`}),`
`,t(i.p,{children:`Both have the same filename, the same symbols and the same ABI version. That's
on purpose: it means a CI machine with no camera and no accelerator can link
and run the same code your app does, without you keeping a second code path
alive.`}),`
`,t(i.p,{children:[`It also means your app can't tell them apart by looking, which is what
`,t(i.code,{children:`goss_capabilities`}),` is for.`]}),`
`,t(i.h2,{id:`asking`,children:t(i.a,{href:`#asking`,children:`Asking`})}),`
`,t(e,{children:t(i.pre,{className:`shiki shiki-themes vitesse-light vitesse-dark`,style:{"--shiki-light":`#393a34`,"--shiki-dark":`#dbd7caee`,"--shiki-light-bg":`#ffffff`,"--shiki-dark-bg":`#121212`},tabIndex:`0`,children:t(i.code,{children:[t(i.span,{className:`line`,children:[t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:`uint64_t`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:` caps `}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`=`}),t(i.span,{style:{"--shiki-light":`#59873A`,"--shiki-dark":`#80A665`},children:` goss_capabilities`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`();`})]}),`
`,t(i.span,{className:`line`,children:[t(i.span,{style:{"--shiki-light":`#1E754F`,"--shiki-dark":`#4D9375`},children:`if`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:` ((`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:`caps `}),t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:`&`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:` GOSS_CAP_TRACKING`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`)`}),t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:` ==`}),t(i.span,{style:{"--shiki-light":`#2F798A`,"--shiki-dark":`#4C9A91`},children:` 0`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`)`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:` {`})]}),`
`,t(i.span,{className:`line`,children:t(i.span,{style:{"--shiki-light":`#A0ADA0`,"--shiki-dark":`#758575DD`},children:`    /* No tracking in this build. Say so, rather than reporting an empty`})}),`
`,t(i.span,{className:`line`,children:t(i.span,{style:{"--shiki-light":`#A0ADA0`,"--shiki-dark":`#758575DD`},children:`       face list as a camera problem. */`})}),`
`,t(i.span,{className:`line`,children:t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`}`})})]})})}),`
`,t(i.p,{children:`Read it once after you create the engine and keep the answer. It can't change
while the process is running.`}),`
`,t(i.h2,{id:`what-the-bits-cover`,children:t(i.a,{href:`#what-the-bits-cover`,children:`What the bits cover`})}),`
`,t(i.p,{children:`There's a bit for each optional subsystem: tracking and world tracking,
segmentation, ML inference, diffusion, beauty, physics, reconstruction, video
textures, photo capture, recording, audio playback and recording, file access,
scripting, stroke boards and diagnostics.`}),`
`,t(i.p,{children:`Read the current set from the header rather than from this page. New bits get
added as subsystems become optional, and a docs page is the wrong place to find
out one exists.`}),`
`,t(i.h2,{id:`using-them-well`,children:t(i.a,{href:`#using-them-well`,children:`Using them well`})}),`
`,t(i.p,{children:[t(i.strong,{children:`Check the feature, not the platform.`}),` Whether tracking is available depends
on how the library was built, not on what the operating system is called. Code
that checks for a platform and assumes a capability will be wrong on somebody's
install.`]}),`
`,t(i.p,{children:[t(i.strong,{children:`Tell the user.`}),` If your app can see that the engine has no segmentation
compiled in, it can disable the control and say why. If it can't see that, it
shows a control that does nothing.`]}),`
`,t(i.p,{children:[t(i.strong,{children:`Be loud in development.`}),` A stub build in a developer's environment should be
noisy, because otherwise somebody spends an afternoon debugging a camera that
was never the problem. In CI it should be silent, because that's what it's for.`]}),`
`,t(i.h2,{id:`how-this-shows-up-in-errors`,children:t(i.a,{href:`#how-this-shows-up-in-errors`,children:`How this shows up in errors`})}),`
`,t(i.p,{children:[`Calling into a subsystem this build doesn't have returns
`,t(i.code,{children:`GOSS_ERROR_UNSUPPORTED`}),`. That's an answer, not a fault, so map it to something
your app can branch on rather than to an error that unwinds a frame.`]})]})}function i(e={}){let{wrapper:i}={...n(),...e.components};return i?t(i,{...e,children:t(r,{...e})}):r(e)}export{i as default};
//# sourceMappingURL=capabilities-LkEcb9r8.js.map