# Webhook Setup

MagSafe Watch can send a JSON webhook when it decides the Mac was probably
unplugged accidentally. Use the same webhook URL on each Mac you want monitored.

The app posts this payload:

```json
{
  "title": "MacBook unplugged",
  "message": "Power changed to Battery. Check the MagSafe cable.",
  "source": "Your Mac Name"
}
```

## Configure MagSafe Watch

1. Open MagSafe Watch.
2. Open `Notifications`.
3. Enable `Send webhook push notifications for iPhone or Apple Watch`.
4. Open `Advanced Config`.
5. Set `webhookURL` to the provider URL.
6. Save the config file and restart MagSafe Watch.
7. Use `Test Webhook` to confirm the webhook provider. Use the Status page
   diagnostics to confirm each attempt and HTTP result.

## Pushover

Pushover provides native iPhone and Apple Watch notifications.

1. Create a Pushover application.
2. Create a small endpoint or automation that accepts MagSafe Watch JSON and
   calls the Pushover Messages API with your user key and app token.
3. Set MagSafe Watch `webhookURL` to that endpoint.

Use the MagSafe Watch `title` as the Pushover title, `message` as the message,
and `source` in the message body or device name.

## ntfy

ntfy is the simplest direct webhook option.

1. Create or choose a private ntfy topic.
2. Use the topic publish URL as `webhookURL`.
3. If the topic requires authentication, put a small relay in front of it so the
   Mac app does not store long-lived credentials in a plain config file.

For a local/private deployment, point `webhookURL` at your own ntfy server.

## IFTTT

IFTTT can receive a Webhooks event and trigger mobile notifications.

1. Create an IFTTT applet.
2. Choose Webhooks as the trigger.
3. Choose Notifications as the action.
4. Use the IFTTT Webhooks URL as `webhookURL`.
5. Map `title`, `message`, and `source` into the notification text.

## Home Assistant

Home Assistant works well if it already handles your household notifications.

1. Create a Home Assistant webhook automation.
2. Use the webhook URL as `webhookURL`.
3. In the automation, send a notification to the mobile app service.
4. Include `source` so multi-Mac alerts identify the machine.

## Notes

- The app retries network errors, HTTP 429, and HTTP 5xx responses with short
  backoff.
- The Status page diagnostics show whether webhooks were skipped, retried,
  failed, or completed with an HTTP status.
- Avoid putting sensitive API tokens directly in the URL if the Mac is shared.
