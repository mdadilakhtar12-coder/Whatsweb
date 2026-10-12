#!/usr/bin/env bash
# Sends a made-up registration and a made-up payment to your Webinar.gg address, the way Webinar.gg would.
#
#   scripts/test-webinar-webhook.sh "<the address from the app: More > Webinar.gg>"
#
# It then sends the payment a second time (the CRM must not count it twice) and tries a wrong address
# (must be refused). The test student is called TEST Webinar.gg; in the app, More > Webinar.gg >
# "Send a test" > "Remove test data" deletes it again.
set -euo pipefail

URL="${1:-}"
if [ -z "$URL" ] || [[ "$URL" != https://*/functions/v1/webinar-gg/* ]]; then
  echo "Usage: $0 \"https://<project>.supabase.co/functions/v1/webinar-gg/<secret>\""
  echo "The address is in the app: More > Webinar.gg > step 1 (copy button)."
  exit 1
fi

stamp=$(date +%s)
email="webinar-test-${stamp}@example.com"
reg="test_reg_${stamp}"
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
later=$(date -u -d "+2 seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)

post() { # address, body -> prints "HTTP code: answer"
  curl -sS -o /tmp/webinar-test-answer -w "%{http_code}" -X POST "$1" \
    -H "Content-Type: application/json" -d "$2" | tr -d '\n'
  printf ': %s\n' "$(cat /tmp/webinar-test-answer)"
}

registration=$(cat <<JSON
{"event":"registration.created","timestamp":"$now","data":{"registrationId":"$reg","webinarId":"test_webinar","webinarTitle":"TEST webinar (you can delete this)","name":"TEST Webinar.gg","email":"$email","status":"approved","paymentStatus":"pending","registeredAt":"$now"}}
JSON
)
payment=$(cat <<JSON
{"event":"registration.payment.completed","timestamp":"$later","data":{"registrationId":"$reg","webinarId":"test_webinar","email":"$email","paymentId":"test_pay_${stamp}","orderId":"test_order_${stamp}","ticketAmount":149,"processingFee":3,"totalCharged":152,"currency":"INR","status":"paid"}}
JSON
)

echo "1. registration.created for $email"
printf '   '; post "$URL" "$registration"
echo "2. registration.payment.completed (Rs 149)"
printf '   '; post "$URL" "$payment"
echo "3. the same payment again (should say duplicate)"
printf '   '; post "$URL" "$payment"
echo "4. an event the CRM does not need (webinar.started): still answered 200"
printf '   '; post "$URL" "{\"event\":\"webinar.started\",\"timestamp\":\"$now\",\"data\":{\"webinarId\":\"test_webinar\"}}"
echo "5. a wrong address (should be 404)"
printf '   '; post "${URL%/*}/not-the-secret-address" "$registration"

echo
echo "Now open the app: More > Webinar.gg > Latest events (all green), and Leads: 'TEST Webinar.gg' shows Paid ₹149."
echo "Remove it afterwards: More > Webinar.gg > Send a test > Remove test data."
