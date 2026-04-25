# Sleep Watch Architecture

The watchOS app reads the previous night's Apple HealthKit sleep samples, sends them to GitHub with a `repository_dispatch` event, and then reads the generated Markdown summary back from the repository.

## Flow

1. Apple Watch schedules a background refresh for the next local 09:00.
2. The watch reads HealthKit `sleepAnalysis` category samples from yesterday 18:00 through today 12:00.
3. The watch sends `repository_dispatch` with event type `sleep_data`.
4. GitHub Actions runs `.github/workflows/sleep-analysis.yml`.
5. `scripts/analyze_sleep.py` calls the Responses API with `gpt-5.4-mini`.
6. The workflow writes:
   - `data/YYYY-MM-DD.json`
   - `summaries/YYYY-MM-DD.md`
7. The watch fetches `summaries/YYYY-MM-DD.md` from GitHub and shows it in the app or a local notification.

GitHub Actions cannot directly push a notification to an Apple Watch without an APNs provider service. This project uses watch-side polling instead.

