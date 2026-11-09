import{f as e}from"./index-ChXJvP0h.js";import{t}from"./jsx-runtime-73cbSzV3.js";import{n}from"./lib-C719NGBq.js";function r(r){let i={a:`a`,code:`code`,h2:`h2`,li:`li`,p:`p`,pre:`pre`,span:`span`,strong:`strong`,table:`table`,tbody:`tbody`,td:`td`,th:`th`,thead:`thead`,tr:`tr`,ul:`ul`,...n(),...r.components};return t(e,{children:[t(i.p,{children:`An agent is a first-class caller rather than a feature bolted on. The engine
ships an MCP server: one static binary speaking JSON-RPC over stdio across the
same C ABI every SDK uses, so a model can open a camera or a screen, ask what
is in frame, and draw back into it with no runtime to install.`}),`
`,t(e,{children:t(i.pre,{className:`shiki shiki-themes vitesse-light vitesse-dark`,style:{"--shiki-light":`#393a34`,"--shiki-dark":`#dbd7caee`,"--shiki-light-bg":`#ffffff`,"--shiki-dark-bg":`#121212`},tabIndex:`0`,children:t(i.code,{children:t(i.span,{className:`line`,children:[t(i.span,{style:{"--shiki-light":`#59873A`,"--shiki-dark":`#80A665`},children:`zig`}),t(i.span,{style:{"--shiki-light":`#B56959`,"--shiki-dark":`#C98A7D`},children:` build`}),t(i.span,{style:{"--shiki-light":`#B56959`,"--shiki-dark":`#C98A7D`},children:` mcp`})]})})})}),`
`,t(i.p,{children:`The tools answer from the engine itself. A tool whose precondition is missing
names that one precondition rather than returning a generic refusal, and the
engine and its session come up on the first call that needs one.`}),`
`,t(i.h2,{id:`the-tools`,children:t(i.a,{href:`#the-tools`,children:`The tools`})}),`
`,t(i.p,{children:t(i.strong,{children:`Getting frames in`})}),`
`,t(i.table,{children:[t(i.thead,{children:t(i.tr,{children:[t(i.th,{children:`Tool`}),t(i.th,{children:`What it does`})]})}),t(i.tbody,{children:[t(i.tr,{children:[t(i.td,{children:t(i.code,{children:`open_clip`})}),t(i.td,{children:`Read from a clip`})]}),t(i.tr,{children:[t(i.td,{children:t(i.code,{children:`open_screen`})}),t(i.td,{children:`Read from a shared screen`})]}),t(i.tr,{children:[t(i.td,{children:t(i.code,{children:`submit_image`})}),t(i.td,{children:`Hand over a single image`})]})]})]}),`
`,t(i.p,{children:t(i.strong,{children:`Asking what is there`})}),`
`,t(i.table,{children:[t(i.thead,{children:t(i.tr,{children:[t(i.th,{children:`Tool`}),t(i.th,{children:`What it does`})]})}),t(i.tbody,{children:[t(i.tr,{children:[t(i.td,{children:t(i.code,{children:`read_perception`})}),t(i.td,{children:[`The `,t(i.a,{href:`/docs/concepts/perception`,children:`perception record`})]})]}),t(i.tr,{children:[t(i.td,{children:t(i.code,{children:`read_text`})}),t(i.td,{children:`Recognised text with its reading order`})]}),t(i.tr,{children:[t(i.td,{children:t(i.code,{children:`engine_report`})}),t(i.td,{children:`Budget, degrade level and counters`})]}),t(i.tr,{children:[t(i.td,{children:t(i.code,{children:`model_support`})}),t(i.td,{children:`Whether a network's operations are available`})]})]})]}),`
`,t(i.p,{children:t(i.strong,{children:`Space`})}),`
`,t(i.table,{children:[t(i.thead,{children:t(i.tr,{children:[t(i.th,{children:`Tool`}),t(i.th,{children:`What it does`})]})}),t(i.tbody,{children:[t(i.tr,{children:[t(i.td,{children:t(i.code,{children:`submit_world`})}),t(i.td,{children:`Pose, planes, anchors and light`})]}),t(i.tr,{children:[t(i.td,{children:t(i.code,{children:`submit_world_mesh`})}),t(i.td,{children:`The scanned geometry`})]}),t(i.tr,{children:[t(i.td,{children:t(i.code,{children:`floor_plane`})}),t(i.td,{children:`Which surface is the floor`})]}),t(i.tr,{children:[t(i.td,{children:t(i.code,{children:`place_on`})}),t(i.td,{children:`Put a footprint on a surface, and what is left`})]}),t(i.tr,{children:[t(i.td,{children:t(i.code,{children:`measure_between`})}),t(i.td,{children:`Distance, with the error its inputs carried`})]}),t(i.tr,{children:[t(i.td,{children:t(i.code,{children:`path_across_world`})}),t(i.td,{children:`A route across scanned geometry`})]}),t(i.tr,{children:[t(i.td,{children:t(i.code,{children:`align_shared`})}),t(i.td,{children:`The transform between two devices' origins`})]}),t(i.tr,{children:[t(i.td,{children:t(i.code,{children:`screen_point`})}),t(i.td,{children:`Where a world point lands on screen`})]})]})]}),`
`,t(i.p,{children:t(i.strong,{children:`Marking and recall`})}),`
`,t(i.table,{children:[t(i.thead,{children:t(i.tr,{children:[t(i.th,{children:`Tool`}),t(i.th,{children:`What it does`})]})}),t(i.tbody,{children:[t(i.tr,{children:[t(i.td,{children:t(i.code,{children:`annotate`})}),t(i.td,{children:`Leave a mark in the scene`})]}),t(i.tr,{children:[t(i.td,{children:t(i.code,{children:`remember`})}),t(i.td,{children:`Keep something worth recalling`})]}),t(i.tr,{children:[t(i.td,{children:t(i.code,{children:`search_memory`})}),t(i.td,{children:`Find it again`})]})]})]}),`
`,t(i.h2,{id:`spatial-questions-are-answered-not-computed-by-the-caller`,children:t(i.a,{href:`#spatial-questions-are-answered-not-computed-by-the-caller`,children:`Spatial questions are answered, not computed by the caller`})}),`
`,t(i.p,{children:`Because the engine already holds planes and anchors, an agent asks the spatial
question directly rather than fetching geometry and doing trigonometry on it.`}),`
`,t(i.p,{children:[`That matters for correctness as much as for convenience: `,t(i.code,{children:`measure_between`}),`
returns the distance with the error bar its inputs carried, which a caller
recomputing from raw points would have to derive and would usually drop.`]}),`
`,t(i.h2,{id:`scope-is-a-boundary`,children:t(i.a,{href:`#scope-is-a-boundary`,children:`Scope is a boundary`})}),`
`,t(i.p,{children:`A session's scope governs what each tool will answer. The server says so in
its own description, and the check happens at every operation a verb covers
rather than once at connection time.`}),`
`,t(i.p,{children:`The verbs a build knows are readable from the ABI, so a host can present them
rather than hard-coding a list:`}),`
`,t(e,{children:t(i.pre,{className:`shiki shiki-themes vitesse-light vitesse-dark`,style:{"--shiki-light":`#393a34`,"--shiki-dark":`#dbd7caee`,"--shiki-light-bg":`#ffffff`,"--shiki-dark-bg":`#121212`},tabIndex:`0`,children:t(i.code,{children:[t(i.span,{className:`line`,children:[t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:`uint32_t`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:` count `}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`=`}),t(i.span,{style:{"--shiki-light":`#59873A`,"--shiki-dark":`#80A665`},children:` goss_scope_verb_count`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`();`})]}),`
`,t(i.span,{className:`line`,children:[t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:`const`}),t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:` char`}),t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:` *`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:`name `}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`=`}),t(i.span,{style:{"--shiki-light":`#59873A`,"--shiki-dark":`#80A665`},children:` goss_scope_verb_name`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`(`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:`index`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`);`})]})]})})}),`
`,t(i.p,{children:`A session's scope only narrows. Widening means a new session, so a scope
cannot quietly grow during a conversation.`}),`
`,t(i.h2,{id:`everything-stays-on-the-device`,children:t(i.a,{href:`#everything-stays-on-the-device`,children:`Everything stays on the device`})}),`
`,t(i.p,{children:`No tool here sends a frame anywhere. That is a property of the engine rather
than a promise of the server: there is no network path in the core, so the
server has nothing to send with.`}),`
`,t(i.h2,{id:`writing-an-agent-against-it`,children:t(i.a,{href:`#writing-an-agent-against-it`,children:`Writing an agent against it`})}),`
`,t(i.p,{children:`The same rules the SDKs follow apply:`}),`
`,t(i.ul,{children:[`
`,t(i.li,{children:[`Ask `,t(i.code,{children:`engine_report`}),` rather than timing calls from outside.`]}),`
`,t(i.li,{children:[`Check `,t(i.code,{children:`model_support`}),` before offering a model, not after loading it.`]}),`
`,t(i.li,{children:`A refusal from scope is a request to the host; a refusal from capabilities
is a fact about the build. Tell them apart before retrying.`}),`
`]})]})}function i(e={}){let{wrapper:i}={...n(),...e.components};return i?t(i,{...e,children:t(r,{...e})}):r(e)}export{i as default};
//# sourceMappingURL=agents-Dciab0ZO.js.map