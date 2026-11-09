import{f as e}from"./index-ChXJvP0h.js";import{t}from"./jsx-runtime-73cbSzV3.js";import{n}from"./lib-C719NGBq.js";function r(r){let i={a:`a`,code:`code`,h2:`h2`,li:`li`,p:`p`,pre:`pre`,span:`span`,strong:`strong`,ul:`ul`,...n(),...r.components};return t(e,{children:[t(i.p,{children:`The engine is built to a budget per frame rather than to a target frame rate,
because a frame that arrives late is worse than a frame that did less.`}),`
`,t(i.h2,{id:`the-budget`,children:t(i.a,{href:`#the-budget`,children:`The budget`})}),`
`,t(i.p,{children:[`A session carries `,t(i.code,{children:`frame_budget_us`}),`: the ceiling for everything the engine does
between a frame arriving and the result being ready. Zero means the engine
picks from what the device can sustain.`]}),`
`,t(i.p,{children:[`When the work will not fit, the engine does not drop the frame. It climbs down
the `,t(i.a,{href:`/docs/concepts/degradation`,children:`degradation ladder`}),` in a fixed, documented
order, so the thing that gets worse is the thing you chose in advance rather
than whatever happened to be last in the queue.`]}),`
`,t(i.p,{children:`Set the budget from the refresh rate you are drawing at, leaving the
application its own share. A budget that consumes the whole frame interval
leaves nothing for the compositor and shows up as judder that profiles blame
on the engine.`}),`
`,t(i.h2,{id:`what-copies-and-what-does-not`,children:t(i.a,{href:`#what-copies-and-what-does-not`,children:`What copies and what does not`})}),`
`,t(i.p,{children:`The common path copies nothing. A frame arrives as a platform texture or a
hardware buffer, is imported, and is used where it is.`}),`
`,t(i.p,{children:`The copying paths exist and are correct, and they are there for bringing a
platform up rather than for shipping:`}),`
`,t(i.ul,{children:[`
`,t(i.li,{children:`A planes-and-strides submit stages the frame through the engine's own
staging pool.`}),`
`,t(i.li,{children:`An RGBA copy submit converts on the way in.`}),`
`]}),`
`,t(i.p,{children:`If a profile shows time in staging on a platform that has a shared texture
path, the integration is on the wrong call rather than the engine being slow.`}),`
`,t(i.h2,{id:`allocation`,children:t(i.a,{href:`#allocation`,children:`Allocation`})}),`
`,t(i.p,{children:`Nothing in the engine allocates per frame on the common path. Pools are sized
at creation and reused.`}),`
`,t(i.p,{children:`A binding can undo that on its own, and usually does so in one of two ways:
building a fresh descriptor object per frame, or materialising the record into
new objects per frame. Reuse the descriptor. Hand the record back as a view
where your language allows one, and as a reused buffer where it does not.`}),`
`,t(i.h2,{id:`pool-exhaustion-is-a-signal`,children:t(i.a,{href:`#pool-exhaustion-is-a-signal`,children:`Pool exhaustion is a signal`})}),`
`,t(i.p,{children:[t(i.code,{children:`GOSS_ERROR_POOL_EXHAUSTED`}),` means every buffer is still held by the caller. It
is a backpressure signal rather than a failure: stop pulling frames until the
engine has caught up.`]}),`
`,t(i.p,{children:`Raising the capacity is occasionally right and usually postpones the problem.
A pool twice the size exhausts twice as late and stalls for twice as long.`}),`
`,t(i.h2,{id:`measuring`,children:t(i.a,{href:`#measuring`,children:`Measuring`})}),`
`,t(i.p,{children:`Read the engine's own numbers rather than wrapping calls in timers. A wall
clock around a submit says the frame took eight milliseconds; the node report
says which node spent six of them.`}),`
`,t(e,{children:t(i.pre,{className:`shiki shiki-themes vitesse-light vitesse-dark`,style:{"--shiki-light":`#393a34`,"--shiki-dark":`#dbd7caee`,"--shiki-light-bg":`#ffffff`,"--shiki-dark-bg":`#121212`},tabIndex:`0`,children:t(i.code,{children:t(i.span,{className:`line`,children:[t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:`goss_degrade_level level `}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`=`}),t(i.span,{style:{"--shiki-light":`#59873A`,"--shiki-dark":`#80A665`},children:` goss_session_report_frame`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`(`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:`session`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`,`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:` frame_time_us`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`,`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:` thermal`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`);`})]})})})}),`
`,t(i.p,{children:[`That one call both drives the ladder and tells you where it settled. Feed it
your platform's real thermal state; see `,t(i.a,{href:`/docs/concepts/degradation`,children:`degradation`}),`.`]}),`
`,t(i.p,{children:[`Then take the engine section of the record, which carries the budget, what was
spent, the degrade level, `,t(i.code,{children:`degrade_transitions`}),`, `,t(i.code,{children:`nodes_degraded`}),` and
`,t(i.code,{children:`node_reports_lost`}),`:`]}),`
`,t(e,{children:t(i.pre,{className:`shiki shiki-themes vitesse-light vitesse-dark`,style:{"--shiki-light":`#393a34`,"--shiki-dark":`#dbd7caee`,"--shiki-light-bg":`#ffffff`,"--shiki-dark-bg":`#121212`},tabIndex:`0`,children:t(i.code,{children:t(i.span,{className:`line`,children:[t(i.span,{style:{"--shiki-light":`#59873A`,"--shiki-dark":`#80A665`},children:`goss_session_perception_json`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`(`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:`session`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`,`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:` GOSS_PERCEPTION_ENGINE`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`,`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:` buf`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`,`}),t(i.span,{style:{"--shiki-light":`#393A34`,"--shiki-dark":`#DBD7CAEE`},children:` cap`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`,`}),t(i.span,{style:{"--shiki-light":`#AB5959`,"--shiki-dark":`#CB7676`},children:` &`}),t(i.span,{style:{"--shiki-light":`#B07D48`,"--shiki-dark":`#BD976A`},children:`written`}),t(i.span,{style:{"--shiki-light":`#999999`,"--shiki-dark":`#666666`},children:`);`})]})})})}),`
`,t(i.p,{children:`Three numbers tell you most of what you need:`}),`
`,t(i.ul,{children:[`
`,t(i.li,{children:[t(i.strong,{children:`spent against limit.`}),` Headroom, or the lack of it.`]}),`
`,t(i.li,{children:[t(i.strong,{children:`degrade_transitions.`}),` A number that keeps climbing means flapping, and
flapping costs more than sitting one step lower.`]}),`
`,t(i.li,{children:[t(i.strong,{children:`node_reports_lost.`}),` The measurements themselves are incomplete.`]}),`
`]}),`
`,t(i.p,{children:`Measure cold, because the first frame is the one the user waits on. Measure
again after several minutes, because a device that is comfortable for thirty
seconds and throttled at three minutes has a different problem.`}),`
`,t(i.h2,{id:`before-shipping`,children:t(i.a,{href:`#before-shipping`,children:`Before shipping`})}),`
`,t(i.ul,{children:[`
`,t(i.li,{children:`The budget is set from the refresh rate, not left at a guess.`}),`
`,t(i.li,{children:`The platform's zero-copy submit is the one in use, confirmed by a profile
rather than by reading the code.`}),`
`,t(i.li,{children:`Nothing allocates per frame in the binding.`}),`
`,t(i.li,{children:`Exhaustion produces backpressure, proven by holding frames on purpose.`}),`
`,t(i.li,{children:`The device is still cool after several minutes of continuous use.`}),`
`]})]})}function i(e={}){let{wrapper:i}={...n(),...e.components};return i?t(i,{...e,children:t(r,{...e})}):r(e)}export{i as default};
//# sourceMappingURL=performance-BBQ0YyVP.js.map