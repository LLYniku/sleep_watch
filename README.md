# Apple Watch AI Health Coach

A native watchOS app that reads Apple Watch / HealthKit data, sends it to a GitHub Actions workflow, analyzes it with an OpenAI-compatible model, stores only an encrypted report in the repository, and shows a short local notification on Apple Watch.

The project is designed as a personal, self-hosted health report pipeline. It is suitable for anyone who wants a small Apple Watch app that turns their own HealthKit data into a private daily coaching report.

Each user should run their own repository, secrets, token, encryption key, bundle identifier, and Apple Developer signing setup. This repository does not include personal data, API keys, GitHub tokens, HealthKit exports, or user-specific configuration.

## Features

- Reads HealthKit sleep, activity, heart rate, HRV, respiratory, oxygen saturation, stand, distance, and energy metrics.
- Triggers a GitHub Actions workflow from Apple Watch.
- Uses an OpenAI-compatible API to generate a structured Chinese health report.
- Encrypts generated reports with AES-256-GCM before committing them to GitHub.
- Keeps raw HealthKit payloads and plaintext reports out of the repository.
- Schedules a local 09:00 watchOS background refresh when the system allows it.
- Sends a local Apple Watch notification after a report is generated and decrypted.
- Supports a private `USER_PERSONA` GitHub Secret so advice can match the user's lifestyle, work, study, and recovery needs without exposing that profile in the repository.

## Who This Is For

- Apple Watch users who want a private daily health summary.
- People who prefer to keep the app simple on the watch and run heavier analysis in GitHub Actions.
- Developers who are comfortable configuring GitHub Actions secrets, Xcode signing, and HealthKit permissions.
- Users who want the prompt to reflect their own routine, work style, recovery needs, and preferred tone.

## Privacy Model

- Use a separate GitHub repository per user. Do not share one repository across multiple people.
- The Watch app uploads raw HealthKit data to GitHub Actions over HTTPS so the workflow can analyze it.
- GitHub Actions and the configured model provider can process the raw payload during a run.
- Personal prompt/profile text is not sent from the Watch app. Store it only as the `USER_PERSONA` GitHub Actions secret.
- The repository should only commit encrypted reports: `reports/*.json.enc`.
- Raw payloads, Markdown summaries, and plaintext JSON reports are ignored and should not be committed.
- Never commit `OPENAI_API_KEY`, the Watch GitHub token, or `HEALTH_REPORT_KEY`.
- The Watch app decrypts reports locally with `reportEncryptionKey`.
- Treat GitHub Actions logs as sensitive operational logs. The workflow is designed not to print raw HealthKit payloads.

## GitHub Setup

1. Fork or create a new repository from this project.
2. In repository settings, add Actions secrets:
   - `OPENAI_API_KEY`: an OpenAI-compatible API key.
   - `HEALTH_REPORT_KEY`: a base64-encoded 32-byte AES key. The Watch app must use the same value in `SleepWatch/Config.swift`.
   - `USER_PERSONA`: private personalization text used by the analysis prompt. Do not put this in `Config.swift` or the repository.
3. Add repository variables:
   - `OPENAI_API_BASE=https://api.openai.com/v1` or another OpenAI-compatible endpoint.
   - `OPENAI_MODEL=gpt-5.4-mini` or another model supported by your endpoint.
   - `OPENAI_WIRE_API=responses`
   - `OPENAI_DISABLE_RESPONSE_STORAGE=true`
   - `OPENAI_REASONING_EFFORT=xhigh`
4. Create a fine-grained GitHub personal access token for this repository. The Watch app uses it to trigger the workflow and read encrypted reports.
   - Repository access: only this repository.
   - Permissions: `Actions: Read and write`, `Contents: Read-only`.
5. Update local `SleepWatch/Config.swift`:
   - `githubOwner`
   - `githubRepo`
   - `githubBranch`
   - `githubToken`
   - `reportEncryptionKey`

You can store the Watch token and generate a local report encryption key with:

```bash
python3 scripts/set_watch_token.py
```

Then set the printed/generated encryption key as the repository secret `HEALTH_REPORT_KEY`. The same key must exist in the Watch app and GitHub Actions.

## Personalization

Set `USER_PERSONA` as a GitHub Actions secret. Keep it concise and practical. Examples:

- `Night-shift worker who wants sleep recovery advice and gentle reminders.`
- `Desk-based software developer who wants posture, movement, and stress-management suggestions.`
- `Student preparing for exams who prefers encouraging language and realistic rest advice.`

The workflow uses this secret only to guide the analysis tone and recommendations. It is not committed, not sent by the Watch app, and should not be printed in workflow logs.

## Xcode Setup

1. Open `SleepWatch.xcodeproj`.
2. Select target `SleepWatch`.
3. Change the bundle identifier to your own unique bundle id.
4. Set your Apple Developer Team under Signing & Capabilities.
5. Ensure HealthKit capability is enabled.
6. Select a connected Apple Watch as the run destination and run the app.
7. On first launch, grant HealthKit and notification permissions.

## Daily Behavior

The app schedules a background refresh for local 09:00 and tries to upload the previous day's health data. watchOS background refresh is opportunistic, so it may not run at the exact minute every day.

The "生成健康报告" button forces an analysis run when the app is open.

The Watch app does not keep a local report history. It fetches the encrypted report into memory, decrypts it locally, converts it into a short notification body, and posts one local notification with the fixed identifier `daily-health-summary`.

## Repository Name

You can rename the repository at any time. Existing GitHub stars, issues, Actions secrets, variables, and workflow history stay with the repository, and GitHub usually redirects the old URL.

After renaming, update:

- The local Git remote: `git remote set-url origin https://github.com/YOUR_USER/NEW_REPOSITORY_NAME.git`
- `githubRepo` in `SleepWatch/Config.swift`
- Any fine-grained GitHub token permissions if the token stops working after the rename

Then rebuild and reinstall the Watch app because the repository name is compiled into the app configuration.

## Manual Workflow Test

Run the GitHub Action manually with a payload like:

```json
{
  "analysis_date": "2099-01-01",
  "window_start": "2098-12-31T00:00:00Z",
  "window_end": "2099-01-01T00:00:00Z",
  "sleep_window_start": "2098-12-31T18:00:00Z",
  "sleep_window_end": "2099-01-01T12:00:00Z",
  "generated_at": "2099-01-01T09:00:00Z",
  "source": "manual_test",
  "sleep_samples": [
    {
      "stage": "asleep_core",
      "start": "2098-12-31T23:30:00Z",
      "end": "2099-01-01T05:30:00Z",
      "duration_minutes": 360,
      "raw_value": 3
    }
  ],
  "quantity_metrics": [
    {
      "id": "steps",
      "title": "步数",
      "unit": "步",
      "aggregation": "sum",
      "value": 6000,
      "average": null,
      "minimum": null,
      "maximum": null,
      "sample_count": 1,
      "start": "2098-12-31T00:00:00Z",
      "end": "2099-01-01T00:00:00Z"
    }
  ],
  "stand_hours": [],
  "data_gaps": []
}
```
