/****************************************************************************
 * Personal Zen Browser preferences (dotProd)                              *
 *                                                                          *
 * Curated by hand. Zen already ships sane defaults for most performance/  *
 * privacy tuning and has its own native vertical-tabs implementation and  *
 * blank-new-tab behavior, so this file only sets prefs Zen does NOT       *
 * already cover by default.                                              *
****************************************************************************/

/** DNS ***/
user_pref("doh-rollout.mode", 2); // enable DoH with fallback
user_pref("doh-rollout.uri", "https://mozilla.cloudflare-dns.com/dns-query");

/** PASSWORDS / AUTOFILL (using an external password manager) ***/
user_pref("signon.rememberSignons", false);
user_pref("extensions.formautofill.addresses.enabled", false);
user_pref("extensions.formautofill.creditCards.enabled", false);
