Please red-team PR #{{PR}} of this repo and look for any security concerns. Also check that the PR summary is according to the code changes. Give your verdict, either `pass`, `pass-with-comments`, or `blocked-with-comments`.

{{#RE_REVIEW}}
This is a re-review. The previous red-team pass returned **{{PRIOR_VERDICT}}** at commit `{{PRIOR_SHA}}`. Read that prior red-team verdict comment on the PR and, for each concern it raised, say whether it is now addressed, still open, or regressed — so every prior concern gets closure.

{{/RE_REVIEW}}
End your reply with a single line and nothing after it:

VERDICT: <pass | pass-with-comments | blocked-with-comments>
