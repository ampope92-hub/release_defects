# fieldbook-mobile defect reports, tracker export of 2025-08-04

Three files from the tracker, covering every release of the 7.x line.

## releases.csv

One row per release: `version`, `release_date`, `installs_first_90_days` (installs counted over
the release's first 90 days, the figure the review uses as a release's size) and
`crash_reporter`, `yes` for a release that ships the in-app crash reporter, which went in with
7.16. One earlier release, 7.15, ran a short pilot with an early build that phoned crash logs
home in slow weekly batches rather than within days, so its own `crash_reporter` still reads no.
The arrival curve's crash cohort is the releases marked `yes`, not the releases that happen to
carry a crash row.

## reports.csv

Every defect report received up to the export date, one row each: `report_id`, `version`
(the release the report is filed against), `reported_date` (the day the tracker logged it),
`source` (`ticket` for a report filed through the support desk, `crash` for one sent by the
crash reporter), `status` and `opened_date`. A report is filed against exactly one release and
is never moved.

`status` is `open`, `duplicate` or `invalid`. A duplicate or invalid report is not a defect.
Drop it everywhere: not in a column count, not in a curve, not in the count a release divides
by its curve.

`opened_date` is the day the user actually hit the bug. For a crash report that is the same day
as `reported_date`, since the reporter files within days and there is no queue in between. For a
ticket, `reported_date` is only the day the tracker logged the report, and it can trail
`opened_date` by a triage queue. Build every column count from `opened_date`, never from
`reported_date`.

A report reaches the tracker some time after the release it belongs to. A ticket is written when
a user gets round to writing it, usually weeks and often months after the release the report is
filed against; a crash report is sent by the reporter within days of the crash that produced it.
So the reports a release has against it on the export date are only the share of its eventual
reports that its age has allowed to arrive, and that share is not the same for the two sources.
The releases already past day 365 are the ones that have finished collecting.

A release's age in days sets how many complete thirty-day columns the export holds for it. An
age of A days is A+1 days of history, today included, so it holds floor((A+1)/30) complete
columns. A release 29 days old holds one, covering days 0 to 29. A release 100 days old holds
three, the third covering days 0 to 89. An N-day column counts a report whose opened lag from
the release date is 0 to N-1 days; the day-365 total counts opened lag 0 to 365 days.

## policy.json

| key | meaning |
|---|---|
| product | the product |
| export_date | the day the export was taken; no report after it is in the file |
| horizon_days | the horizon support plans against, 365 days after each release |
| forecast_releases | the releases support wants a number for, one of them already past day 365 but kept on the list for the quarterly comparison |
| tolerance_per_release | how far a forecast may be from the count a release reaches |
| tolerance_total | how far the summed forecasts may be from the summed counts |
| reports_per_10k_installs_to_date | the table from the release review, see below |

## From the release review

The review's table is, for each release, the reports received by the export date divided by
the release's installs, per ten thousand installs. On that table the last five releases sit
under the figures of the releases before them, and the review recorded it as an improvement.
