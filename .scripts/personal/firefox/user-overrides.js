/****************************************************************************
 * Personal overrides (dotProd)                                            *
 *                                                                          *
 * Curated by hand from a previous machine's profile. Loaded AFTER         *
 * Betterfox's user.js by .scripts/gui/firefox.sh.tmpl, so anything here   *
 * wins over the Betterfox defaults.                                       *
 *                                                                          *
 * Kept deliberately small: only settings that reflect an actual choice,   *
 * not Firefox's session/telemetry/UI-state noise and not anything already *
 * covered by Betterfox itself.                                           *
****************************************************************************/

/** STARTUP / NEW TAB ***/
user_pref("browser.newtabpage.enabled", false);
user_pref("browser.startup.homepage", "chrome://browser/content/blanktab.html");

/** SIDEBAR / TABS ***/
user_pref("sidebar.revamp", true);
user_pref("sidebar.verticalTabs", true);
user_pref("sidebar.visibility", "expand-on-hover");

/** DNS ***/
user_pref("doh-rollout.mode", 2); // enable DoH with fallback
user_pref("doh-rollout.uri", "https://mozilla.cloudflare-dns.com/dns-query");

/** PASSWORDS / AUTOFILL (using an external password manager) ***/
user_pref("signon.rememberSignons", false);
user_pref("extensions.formautofill.addresses.enabled", false);
user_pref("extensions.formautofill.creditCards.enabled", false);

/** SANITIZATION ***/
user_pref("privacy.clearOnShutdown_v2.formdata", true);
