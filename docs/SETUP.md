# Setup guide (ek baar karna hai)

Poora setup free hai. Database, server functions aur settings GitHub apne aap karta hai
(`scripts/supabase-deploy.sh`) — aapko sirf accounts banane hain aur 4 secrets daalne hain.

---

## Step 1 — Supabase project

1. **supabase.com** → **Start your project** → **Continue with GitHub**.
2. Organization: koi bhi naam, **Personal**, plan **Free**.
3. **New project**:
   - Name: `whatsweb`
   - Database password: **Generate a password** → kahin save kar lo
   - Region: **South Asia (Mumbai)**
4. 1-2 minute mein project ban jayega.

## Step 2 — Supabase se do cheezein copy karni hain

1. **Project ID (ref):** browser ke link mein `supabase.com/dashboard/project/`**`abcdefghijklmnop`**
   — ye 20 letters wala code. (Ya **Project Settings → General → Project ID**.)
2. **Access token:** left-bottom / top-right apne photo pe click → **Account preferences** →
   **Access Tokens** → **Generate new token** → naam `github` → token copy karo
   (sirf ek baar dikhta hai).

## Step 3 — GitHub secrets (4)

GitHub repo → **Settings** → left menu **Secrets and variables → Actions** →
**New repository secret**. Har ek ka Name aur Value daal ke **Add secret**:

| Name | Value |
|---|---|
| `SUPABASE_PROJECT_REF` | Step 2 ka Project ID |
| `SUPABASE_ACCESS_TOKEN` | Step 2 ka access token |
| `KEYSTORE_BASE64` | App signing key (Claude ne file di hai — poora text copy karo) |
| `KEYSTORE_PASSWORD` | Signing key ka password (Claude ne diya hai) |

⚠️ Signing key file aur password Google Drive mein bhi save kar lo. Ye kho gaye to app ka
update install nahi hoga — sabko app hata ke dobara install karna padega.

## Step 4 — Server setup + APK

GitHub repo → **Actions** → **Build APK** → **Run workflow** → **Run workflow**.
~10 minute. Dono hare tick aane chahiye: **Server (Supabase)** aur **APK**.

## Step 5 — Apna admin account

Supabase → **Authentication → Users → Add user → Create new user** → apna email + password,
**Auto Confirm User** ON. Pehla user apne aap **Admin** banta hai.

## Step 6 — App install

1. GitHub repo ke right side **Releases** → sabse upar wala → `whatsweb-build-N.apk`.
2. Phone pe download → install. "Install unknown apps" allow karo; Play Protect warning aaye
   to **More details → Install anyway**.
3. Step 5 wale email/password se login.
4. **More → Make reminders reliable** (har phone pe ek baar).

## Step 7 — Team

App → **Team** → **Add member** → naam, login ID (email jaisa, jaise `ravi@mycrm.in` — koi email
nahi jata), password. Ye ID/password agent ko de do.

---

# Phase 2 — Ads se leads apne aap aana

Webhook address aur key app mein: **More → Lead sources** (sirf admin ko dikhta hai). Ye "landing key" landing page ke andar hoti hai, isliye koi bhi dekh sakta hai: ek visitor / ek number / ek din mein leads ki limit hai (roz 300), aur automatic WhatsApp ki bhi roz ki limit (300).

## Landing page (Meta + Google dono)

- Form ko **Form address** pe POST karo — fields `name`, `phone`, `email` (baaki koi bhi field
  lead ki "Form details" mein dikhegi).
- Ready-made form: `landing-page/index.html` (bas address badalna hai).
- Ad ke link ke end mein: Meta `?utm_source=facebook&utm_campaign={{campaign.name}}`,
  Google `?utm_source=google&utm_campaign={campaignid}`.

## Google Ads Lead Form (account eligible hone ke baad)

Lead form → **Lead delivery → Webhook integration** → Webhook URL + Key (app se copy) →
**Send test data** → app mein "TEST lead from Google Ads" dikhni chahiye.

## Meta Instant Form

Claude ke saath step-by-step. Short mein: Meta developer app → long-lived Page token
(`leads_retrieval`, `pages_show_list`, `pages_read_engagement`, `pages_manage_ads`,
`pages_manage_metadata`) → Supabase Edge Function secrets `META_PAGE_ID`, `META_PAGE_TOKEN`,
`META_VERIFY_TOKEN`, `META_APP_SECRET` → Meta Webhooks (Page → `leadgen`) callback
`https://<PROJECT_REF>.supabase.co/functions/v1/meta-leads` → backup ke liye
`supabase/optional/meta_sync_schedule.sql`.

---

# Push notifications (Firebase) — ek baar

Nayi lead, "lead ko call nahi kiya", aur subah 9 baje ka summary phone pe aane ke liye.

1. **console.firebase.google.com** → apne Google account se → **Create a project** → naam `whatsweb`
   → Google Analytics **off** → Create.
2. Project mein **Android** icon (Add app) → package name: `com.whatsweb.app` → **Register app**
   → **google-services.json download** karo → baaki steps **Next / Skip**.
3. ⚙️ **Project settings → Service accounts → Generate new private key** → ek JSON file download hogi.
4. GitHub secrets mein (dono files Notepad mein kholo, poora text copy-paste):

| Name | Value |
|---|---|
| `FIREBASE_CONFIG` | google-services.json ka poora text |
| `FIREBASE_SERVICE_ACCOUNT` | private key JSON ka poora text |

5. **Actions → Build APK → Run workflow**. Naya APK install karo → login → notification allow.

Settings: **More → Call new leads fast** (kitne minute baad alert, lead doosre ko dena, working hours).

# Google Drive backup — ek baar

App → **More → Google Drive backup** → wahan 4 steps likhe hain (computer pe karna aasaan):
script copy → script.google.com mein paste → Deploy (Web app, Execute as: Me, Access: Anyone)
→ Web app URL app mein paste. Har raat 2 baje saare leads aur history Drive ke
"WhatsWeb Backups" folder mein save honge (30 din tak).

---

# WhatsApp Cloud API — ek baar

Lead aate hi apne aap WhatsApp message, templates, inbox (chats), button dabane se status /
Hot-Warm-Cold, follow-up, broadcast. Sab app ke andar se chalta hai — GitHub secret ya Supabase
mein kuch alag se nahi daalna.

**Meta se chahiye (4 cheezein):** Permanent access token (System User wala, "Never expires"),
Phone number ID, WhatsApp Business Account ID, App secret (aur App ID — picture / video / PDF
wale template ke liye).

1. Naya APK install karo (GitHub Actions ke baad) → **More → WhatsApp (Cloud API)** →
   upar wala card → **Connect WhatsApp**.
2. Token, Phone number ID, Business Account ID, App ID, App secret paste karo → **Save & connect**.
   Token / secret server pe safe rehte hain, app unhe dobara nahi dikhati.
3. Wahin neeche **Callback URL** aur **Verify token** dikhenge (copy button ke saath).
   Meta developer site → apna app → **WhatsApp → Configuration → Webhook → Edit** → dono paste →
   **Verify and save** → **Manage** mein **messages** ke saamne **Subscribe**.
4. Dusre phone se apne WhatsApp number pe message bhejo → app ke **Chats** tab mein dikhna chahiye.
5. **WhatsApp → Templates → New template** → likho, buttons jodo (har quick-reply button ke liye
   "kya ho" chuno) → **Save & send to Meta**. Approve hone pe notification aayegi.
5b. Kuch logon ko seedha number se bhejna ho: **WhatsApp → Send to numbers** → numbers likho,
   template chuno, Send (naye number apne aap lead ban jaate hain).
5c. Template ke text mein **+ Fill when sending** chip se aisi detail daal sakte ho jo bhejte waqt har
   baar khud likhni ho (jaise semester, paper, date). Naam aur ek example likho (example Meta ko jaata
   hai). Bhejte waqt (chat, Send to numbers, Broadcast) us detail ka box aata hai. Maximum 5 details.
   Aise template automatic message / follow-up mein nahi chal sakte (wahan koi box bhar nahi sakta).
   Meta ka niyam: message ke bilkul shuru ya aakhir mein koi variable nahi ho sakta.
6. **WhatsApp → Send WhatsApp automatically** ON → template chuno → apne number se test lead daalo.

Dhyan: pehla message hamesha approved template hota hai; student reply kare to 24 ghante tak
koi bhi message (text, PDF, list, buttons) bheja ja sakta hai. "STOP" likhne wale ko aage
message nahi jaata.

# Webinar.gg — kaun register hua, kisne pay kiya, kaun aaya

Webinar.gg har registration / payment / refund ka message CRM ko bhejta hai. CRM student ko **email**
se lead se jodta hai (email nahi mili to nayi lead banti hai, source "Webinar.gg"). Har lead pe dikhta
hai: *Registered*, *Paid ₹149*, *Payment failed*, *Refunded*, aur webinar ke baad *Attended* /
*Did not attend*. Webinar ka paisa **alag** hai: lead ka status (Admission Done etc.) apne aap nahi
badalta. Sab **More → Webinar.gg** mein hai (sirf admin).

1. **Address** — More → Webinar.gg → step 1 mein lamba address hai (copy button). Webinar.gg →
   Settings → **Developer Settings** → "Webhook callback URL" mein paste karke **Save**. Events tick
   karne ka option nahi hai: Webinar.gg sab events isi address pe bhejta hai, CRM sirf kaam ke
   (`registration.*`) rakhta hai, baaki "not needed" likh ke chhod deta hai. Ye address secret hai,
   kisi ko mat do (screenshot mein bhi mat dikhao).
2. **Kaun aaya** — Webinar.gg se API token banao (Settings → Developer Settings → API Tokens), app mein step 2 ke box mein
   paste karke *Save token*. Token server pe rehta hai, app wapas nahi dikhati, chat mein kabhi mat bhejo.
   Har ghante attendance apne aap aati hai; *Copy attendance now* se turant.
3. **Test** — step 3 → *Send a test*: ek nakli student register + ₹149 pay karta hai, sab "✅" aaye to
   connection theek hai. *Remove test data* se wo hat jata hai. (Computer se test: `scripts/test-webinar-webhook.sh "<address>"`.)
4. **Rupees ya paise** — pehle asli payment ke baad lead pe amount dekho. ₹14,900 dikhe to
   *Amounts* mein Paise chuno; purane amount bhi theek ho jate hain.

Kya hota hai:
- Wahi event do baar aaye to ek hi baar ginta hai. Payment registration se pehle aaye to bhi theek.
- Koi event fail ho jaye to save rehta hai aur har ghante dobara try hota hai (More → Webinar.gg → Latest events).
- Hum Webinar.gg ke list mein payment check karte hain: agar kisi payment wala banda unki list mein
  nahi mila (aadha ghanta baad), wo "paid" nahi ginta aur admin ko notification aati hai.
- Paid students ko WhatsApp bhejna ho: Broadcast → "Webinar" filter (Paid) + "Did not attend" jaisa.
- Dashboard pe "Webinar" card: registered, paid, paisa (refund ke baad), attended, har webinar ka hisaab.

Lead source (UTM / phone): Webinar.gg ka message phone, UTM ya source nahi bhejta. Isliye: landing page
pe form (naam, **phone**, **email**) bharwao, lead wahin se banti hai (source = landing page), phir student
Webinar.gg pe usi **email** se register kare → wahi lead "Paid" ho jati hai. Direct Webinar.gg se aane wale
students ki lead email-only banti hai (phone khali; call / WhatsApp ke liye phone khud bharna padega).
Agar baad mein wo landing page form bhare to dono lead ek ho jati hain.

Dhyan: Webinar.gg ke docs is server se khul nahi paye, isliye message ke naam (registrationId, ticketAmount...)
unke bataye format se liye hain aur thode alag naam bhi pehchante hain. Pehla asli event aane par
"Latest events" mein us pe tap karke dekho; kuch alag ho to uska text Claude ko bhejo (token / address nahi).

# AIFM Education app (Appx) — signup, khareed, cancel hua payment, refund

Appx CMS ke **Webhooks** se app ka har signup / purchase / cancelled payment / demo / contact form / refund
CRM ko aata hai. CRM student ko **phone** se (nahi to e-mail se) lead se jodta hai; koi nahi mila to nayi lead
banti hai (source "AIFM Education app"), duplicate nahi banta. Sab **More → AIFM Education app** mein hai (sirf admin).

| Appx event | CRM mein kya hota hai |
|---|---|
| User Signup | lead banti / milti hai, lead pe "App user" |
| Successful Purchase | lead **Admission Done** (switch se band kar sakte ho), course + amount + expiry lead pe, agent ko notification, "not paid" WhatsApp reminder band |
| Cancelled Payment | agent ke liye 1 ghante baad ka follow-up + notification (kharidna chahta tha) |
| Demo Leads / Website Contact | lead banti hai, note mein demo / contact |
| Payment Refund | lead pe refund, paisa ginti se kam |

**Appx mein ek event ka webhook banana** (6 baar: har event ke liye alag):
1. Appx CMS → Integrations → **Webhooks** → **+**.
2. **Webhook Name**: koi bhi (jaise "CRM signup"). **Select Event**: us event ko chuno.
3. **Webhook URL**: app mein More → AIFM Education app → us event pe tap karo → address copy → yahan paste. (Har event ka address alag hai: aakhir mein signup / purchase / cancelled / demo / contact / refund likha hai.)
4. **Payload Type**: Key-Value Based hi rehne do.
5. **Add Key**: left box mein key ka naam **bilkul waisa hi type karo jaisa app mein likha hai** (jaise `number`), right box se Appx ki field chuno (jaise *Number*). "Add another field" se baaki keys. App mein har event ki poori list hai.
6. Save. Har event ke liye dohrao.

Kam se kam **number** (ya email) har event mein zaroori hai, wahi student ki pehchaan hai. Baaki optional.
"Custom Headers" kuch nahi bharna; address mein hi secret hai (kisi ko mat do, screenshot mein bhi nahi).

**Test**: More → AIFM Education app → step 3 → *Send a test*: nakli student signup karta hai, ₹499 ka course khareedta hai
(do baar bheja, ek baar ginta hai), ek payment cancel karta hai. Sab "✅" aaye to connection theek hai; *Remove test data* se hat jata hai.

Settings (step 2):
- **Mark the lead "Admission Done"** ON/OFF. OFF mein bhi khareed lead pe dikhti hai.
- **From this amount**: is amount se chhoti khareed (₹99 test series, kitab) status nahi badalti.

Kaam ki baatein:
- Wahi event do baar aaye to ek baar ginta hai (10 minute ke andar ka repeat). Wahi Transaction ID dobara aaye to bhi ek hi khareed.
- Event fail ho jaye to save rehta hai aur har ghante dobara try hota hai (Latest events mein tap karke dekho).
- Jisne app mein khareed liya use "pay nahi kiya" wala automatic WhatsApp reminder nahi jaata. Broadcast → Filters → **AIFM Education app** → "Not bought" / "Bought in the app".
- Leads → Filters mein bhi yehi filter hai. Dashboard pe "AIFM Education app" card: signup, khareed, paisa (refund ke baad), cancel, har course ka hisaab.
- Refund mein Appx naam nahi bhejta: Transaction ID (nahi to phone / e-mail) se khareed dhundhi jaati hai.
- Video Watched, Test Submitted, New Course Published, Test Uploaded abhi nahi liye (bahut aate hain, lead ke kaam ke nahi).

Dhyan: Appx ke payload ka asli format hum yahan se dekh nahi paye. Isliye key ke naam kaafi alag-alag pehchaante hain
(number / phone / mobile, email, item / course, amount / payment_amount ...) aur "Datetime / 08-10-2026 10:44" jaisi dates
(din pehle, India time) padh lete hain. Pehla asli event aane par "Latest events" mein tap karke dekho; kuch alag ho to
uska text Claude ko bhejo (address mat bhejo).

# REST API aur outgoing webhooks — bahar ke AI assistant ke liye

Ye Claude connector se alag hai. Connector mein har kaam pe aap Approve dabate ho; API mein aapka AI assistant
**apne aap** padh sakta hai, WhatsApp bhej sakta hai, note likh sakta hai, status badal sakta hai. Isliye chabi (key) ko
paise ki tarah sambhaalo. Sab **More → API & webhooks** mein hai (sirf admin). Poori list: `docs/API.md` (app mein bhi: API documentation).

1. **API address** — step 1 mein hai: `https://<project>.supabase.co/functions/v1/api/v1`. Sirf HTTPS.
2. **Key** — step 2 → *Generate key*. Naam do aur chuno kya kar sakti hai: **Read** (padhna), **Write** (note, status), **Send** (WhatsApp).
   Key **ek hi baar** dikhti hai, copy kar lo (CRM sirf uska fingerprint rakhta hai, wapas nahi dikha sakta). Kho gayi to Revoke karke nayi banao.
   AI assistant har request mein header bhejta hai: `Authorization: Bearer <key>`. 60 request/minute per key.
3. **Bhejne ki hadd** — step 3: 24 ghante mein API se zyada se zyada kitne message (default 200, sab keys milake). Key leak ho jaye to bhi number spam nahi hoga.
   "What the AI did lately" mein har bheja hua message / note / status key ke naam ke saath dikhta hai.
4. **Webhook** — step 4: apna https address paste karo, chaho to secret (*Make a secret* button), switch ON, *Save*, phir *Send a test event*.
   Events: student.created, student.activity, course.purchased, whatsapp.reply, whatsapp.button_click. Har message pe `X-WhatsWeb-Signature`
   (HMAC-SHA256, hex) hota hai. Agar aapka address har request pe `Authorization` header maangta hai to
   *Authorization header value* box mein jo value chahiye wahi likho (jaise `Bearer abc123`): har delivery (asli event, test event, retry)
   mein ye header **bilkul waisa hi** jata hai, aage kuch jodta nahi. Save ke baad value chhupi rehti hai ("type to replace"), wapas nahi dikhti.
   Na pahunche to 3 baar aur try (1, 5, 15 minute baad). *Delivery log* mein har try ka HTTP code aur jawab ke shuru ke 300 akshar dikhte hain (jaise 401 / 403 kyun aaya), *Send again* bhi.

Safety jo API khud rakhti hai:
- STOP likhne wale (opted out) ko dono send endpoints mana kar dete hain (403).
- Free text sirf 24 ghante ke window mein (student ne last 24 ghante mein likha ho); warna 409 aur kuch nahi jata. Tab template bhejo.
- API se gaya har message chat mein **"Sent by AI assistant"** likha dikhta hai; note / status history mein "AI assistant" se.
- API kuch delete nahi karti.
- AI ke apne note / message / status se webhook event nahi banta (loop nahi).

Dhyan:
- App abhi sirf signup, demo, contact, purchase, cancelled payment, refund bhejti hai. Searches / downloads / course views CRM mein nahi aate,
  isliye activities mein bhi nahi hain (Appx ke webhook list mein sirf wahi events hain; "Video Watched" chahiye to bolo).
- "Semester" tab dikhta hai jab lead ke form-details mein semester likha ho ya course ke naam mein ("Sem 3").
- Courses ki list kisi alag catalogue se nahi, un courses se banti hai jinko kisi ne khareeda, demo maanga ya khareedne ki koshish ki.
- Status ke naam CRM ke apne hain (New, No Answer, Interested, Call Back, Not Interested, Admission Done, Wrong Number). "converted" = Admission Done.
  "contacted" jaisa koi status nahi hai; chahiye to More → Statuses mein banao.
- Address `/api/v1/...` ke saath `/functions/v1/api` pehle lagta hai (Supabase ka rasta). Apna domain (jaise api.aifmeducation.in) chahiye to baad mein Cloudflare se joda ja sakta hai.

# Claude connector — Claude app se CRM ka summary aur kaam

Claude app (phone ya claude.ai) mein CRM ka connector jodo, phir Claude se poocho: "aaj ka summary do",
"kaun si campaign se admission aaye", "kis agent ne kam call kiye", "kitne paid aur kitne aaye". Aur bol sakte ho:
"in 20 leads ko Ravi ko de do", "Rahul ko WhatsApp pe fees bhej do". **Claude khud kuch nahi badalta**: wo ek
**request** banata hai, CRM app mein aapko notification aati hai, aap padh ke **Approve / Reject** dabate ho.

1. CRM app → **More → Claude connector** → address copy karo (secret hai, photo / chat mein mat bhejo).
2. Claude app → Settings → Connectors → **+ → Add custom connector** → Name: `AIFM CRM`, "MCP server URL"
   mein address paste → Continue → Add.
3. Naye chat mein pucho: "AIFM CRM se aaj ka summary do." Claude har tool chalane se pehle puch sakta hai (Allow).

**Kya kya kar sakta hai (har ek ka alag ON / OFF switch, shuru mein sab OFF)** — More → Claude connector → "What Claude may ask for":
- WhatsApp chats padhna (sirf padhna)
- naye leads jodna (aapki di list se) · naam / phone / email badalna · status aur Hot/Warm/Cold · remark · follow-up reminder
- leads agents ko dena · ek student ko WhatsApp message (24 ghante ke andar) · template bhejna (50 tak, paisa lagta hai)
- **WhatsApp template aur auto-reply banana** (`wa_build`) · **automatic reminder lagana** (`wa_rules`) — neeche "Claude se poora WhatsApp flow banwana" dekho
- OFF karte hi wo tool Claude ko dikhta bhi nahi. Naya chat kholne par pata chalta hai.
- WhatsApp ki roz ki hadd bhi wahin set hoti hai (shuru mein 200).

**Approve kaise**: More mein "Claude connector" ke saath number dikhta hai → **Claude's requests** → request pe tap →
popup mein saaf likha hota hai kya hoga (kin leads pe, kya badlega, WhatsApp ho to kitna kharcha) → **Approve** ya **Reject**.
Approve dabate hi wo kaam aapke apne login se hota hai. 24 ghante mein jawab nahi diya to request khatam. Remark pe
"(via Claude)" likha aata hai. Naye leads "More → Imported files → Claude · date" folder mein jaate hain (galat ho to
us folder se hata sakte ho).

**Kabhi nahi ho sakta**: leads delete karna, team / password, keys aur tokens, WhatsApp connect / disconnect, ye switches khud badalna.

Suraksha:
- Link leak ho jaye to koi sirf request daal sakta hai; **Approve karne ke liye aapka CRM app login chahiye**. Isiliye
  likhne wale kaam seedhe nahi hote.
- Phone number aur email Claude ko **chhupe** dikhte hain (`91••••••10`, `r***@gmail.com`). Chahiye to switch on karo.
- Lead ke naam / remark / WhatsApp message bahar ke log likhte hain: Claude ko kaha gaya hai ki unhe sirf data
  maane, hukum nahi. Aur kuch bhi badalne se pehle aapka Approve zaroori hai.
- Har call ka record screen pe dikhta hai. Ek minute mein 60 aur ek din mein 2000 se zyada calls band; admin ko notification.
- Address leak ho jaye to **Make a new address**: purana turant band, Claude mein connector hata ke naya address se dobara add karo.
- Chats padhne ya summary ke liye data aapke Claude chat (Anthropic) tak jata hai.

# Claude se poora WhatsApp flow banwana (template + button ke reply + automatic reminder)

Do switch: **Build WhatsApp templates and auto-replies** aur **Set automatic reminders** (More → Claude connector).

**Kaise kaam karte hain (chat mein):**
1. Dono switch ON karo, Claude mein **naya chat** kholo.
2. Claude ko batao: "AIFM CRM ka WhatsApp system dekho aur guide padho." (wo `crm_wa_guide` aur `crm_wa_system` padhta hai:
   kaun se template / auto-reply / follow-up pehle se hain, har button dabane par kya hota hai, Meta ke niyam.)
3. Apni **situation** batao, jaise: "BSc Maths 1st sem ka landing page hai. Jo form bhare use 1 ghante tak dekhna hai;
   pay kar diya to kuch nahi bhejna; pay nahi kiya to template jaye jisme 3 button hon: *Fees batao*, *Call me*, *Abhi nahi*.
   Fees pe fees ka message + 'Ticket lena hai' button, Call me pe status Interested aur agent ko call reminder, Abhi nahi pe
   Not Interested." Claude chat mein poori **planning likh ke dikhata hai** (template ka text, har button, har reply, timing).
   Jab tak aap "haan, sahi hai" na bolo wo kuch nahi banata. Badlav chat mein hi bolo.
4. "Ab CRM mein bana do" bolo. Claude **ek request** banata hai (template + sab replies). **More → Claude connector → Claude's
   requests** mein popup padho (template, har button kya karega, har reply) → **Approve**.
5. Approve se: **template DRAFT** ban jata hai (Meta ko kuch nahi jata) aur **auto-replies** More → WhatsApp → Automatic replies
   mein ban jaate hain (inhe Meta approval nahi lagta). Template kholo (More → WhatsApp → Templates), dekho, **Save & send to Meta**
   aap khud dabate ho. (Heading mein picture / PDF chahiye to wahin lagao.)
6. Meta approve kar de to Claude se bolo: "ab reminder rule lagao" → request → Approve. Rule **paused** banta hai. **More → WhatsApp →
   Automatic reminders** mein switch ON karo (template approved ho tabhi ON hota hai).

**Reminder rule kya karta hai:** "landing page ka naam jisme *landing page one* ho" wale lead ko, aane ke **N minute baad** (5 minute se 3 din),
agar **pay nahi kiya** (Webinar.gg se, email se match) — ya agar usne WhatsApp pe reply nahi kiya, ya dono, ya hamesha — wo template bhejta hai.
- Sirf unhe jo switch ON karne ke **baad** aaye. Har lead ko ek hi baar.
- Time: subah 9 se raat 9 (badal sakte ho). Raat ko aaya lead subah reminder paata hai (3 din tak).
- Band lead (Admission Done, Not Interested...) aur jisne STOP kiya, unhe nahi jata. Paid lead ko queue mein hone par bhi nahi jata.
- Roz ki hadd: welcome message ke saath ginti (shuru mein 300), usse zyada nahi.
- Template mein "fill when sending" (`{ask.x}`) details nahi chalti (koi bhar nahi sakta).

**Claude ye nahi kar sakta:** template Meta ko bhejna, picture / video / PDF heading, mojood template / reply badalna ya delete karna,
welcome message ya follow-up ka ON/OFF. Ye sab aap khud karte ho.

# Lead kahan se aayi — filter aur Excel folder

- Leads list → **Filters**: landing page / form / campaign, Excel file, date, WhatsApp state.
- Har landing page ka alag naam chahiye to form mein chhupa field `page` daalo (jaise
  `landing-page-1`) — wahi "source detail" mein dikhega.
- **More → Imported files**: har Excel upload ek folder, khol ke sirf uske leads, galat upload
  ho gaya to "Remove untouched leads".

# Computer (browser) version

Wahi app Chrome mein bhi chalti hai: leads, filters, Excel import, WhatsApp chats / templates /
broadcast, dashboard. Har build ke saath GitHub Release mein `whatsweb-web-build-N.zip` aati hai
(Actions mein `whatsweb-web` artifact bhi). Us folder ko kisi bhi static hosting par rakh do
(Netlify / Cloudflare Pages / Firebase Hosting) — hosting ke steps jab chaho tab karenge.

- Login wahi ID / password. Agent ko sirf apni leads dikhti hain (database ka rule).
- Computer pe nahi hota: seedha call (number copy ho jata hai), phone ke call log se call record,
  reminder / push notification, app update.
