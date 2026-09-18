# fieldbook-mobile defect reports, tracker export of 2025-08-04

Three files from the tracker, covering every release of the 7.x line. The export date itself is
included: a report opened on 2025-08-04 is in the file, nothing later is. Versions are numbered in
the order the release train was cut, which is not always the order the releases shipped.

## releases.csv

One row per release: `version`, `release_date`, `installs_first_90_days` (installs counted over
the release's first 90 days, the figure the review uses as a release's size) and
`crash_reporter`, `yes` for a release that ships the in-app crash reporter, which went in with
7.16. A release marked `no` gets its reports through the support desk. One of them, 7.15, also
carries rows marked `crash`: a few thousand of its users ran a pilot build that uploaded its
crash logs in weekly batches. The release never shipped the reporter, so its column reads `no`.

## reports.csv

Every defect report received up to the export date, one row each: `report_id`, `version`
(the release the report is filed against), `reported_date` (the day the tracker logged it),
`source` (`ticket` for a report filed through the support desk, `crash` for one sent by the
crash reporter), `status` and `opened_date`. A report is filed against exactly one release and
is never moved.

`status` is `open`, `duplicate` or `invalid`. A duplicate or invalid report is not a defect.

`opened_date` is the day the user actually hit the bug. For a crash report that is the same day
as `reported_date`, since the reporter files within days and there is no queue in between. For a
ticket, `reported_date` is only the day the tracker logged the report, and it trails
`opened_date` by the triage queue, a couple of months as a rule.

A release's day-365 count is its open reports whose `opened_date` falls within 365 days of its
release date. A release at least 365 days old on the export date therefore has that whole
record in the file. A release A days old has A+1 days of history in it, the export date
included.

## How the forecast is made

The forecast tool follows this method, rule for rule.

A report counts only while its `status` is `open`. Its age is the days from the release's
`release_date` to its `opened_date`, and it is opened by day N when that age is at most N, the
day itself included. The day-365 count is the reports opened by day 365.

The finished releases are those at least 365 days old on the export date; this export has
finished releases both with and without the reporter. The ticket curve is one pile of every
finished release's open tickets opened by day 365; its share at age N (30, 60 and so on to 360)
is the part of that pile opened by day N. The crash curve is the same over the crash reports of
the finished releases whose `crash_reporter` column says `yes`.

Every release on the forecast list ships the reporter and is either at least 365 days old or
between 60 and 210 days old. A release at least 365 days old has its whole record, so its
forecast is its day-365 count, both sources together. For a younger release A days old, the last
complete age is N = 30 times floor(A/30). For each source, take the release's open reports opened
by day N and divide by that source's share at age N, which is positive in this export; add the
two figures and round to the nearest whole number.

## policy.json

| key | meaning |
|---|---|
| product | the product |
| export_date | the day the export was taken; no report opened after it is in the file |
| horizon_days | the horizon support plans against, 365 days after each release |
| forecast_releases | the releases support wants a number for; a release stays on the list through the quarterly comparison, so one of them is already past its horizon |
| tolerance_per_release | how far a forecast may be from the count a release reaches |
| tolerance_total | how far the summed forecasts may be from the summed counts |
| reports_per_10k_installs_to_date | the table from the release review, see below |

## From the release review

The review's table is, for each release, the reports received by the export date divided by
the release's installs, per ten thousand installs. On that table the newest releases sit
under the figures of the releases before them, and the review recorded it as an improvement.
