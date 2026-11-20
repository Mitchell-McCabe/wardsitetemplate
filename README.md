# Family ward site

This is a pre-release source template for an independently hosted ward site. Public pages cover attendance check-in, announcements, calendar subscriptions, sign-ups, meeting requests, missionary meals, and Serve & Share. Leaders manage ward records in admin.html.

## Configure a ward copy

1. Use a ward-owned Supabase project. Set its project URL and browser publishable key in config.js, along with the ward name and time zone. Keep private keys and leader passphrases out of the repository.
2. The supabase directory includes the original setup.sql and subsequent changes. A complete fresh-install sequence for this template still needs verification. Test that sequence against an empty project before entering ward data.
3. For this draft, serve the static pages at the root of an HTTPS domain. Calendar and post links use root-relative routes.
4. Run `python3 scripts/package_extension.py your.ward.domain` from the repository root and include the resulting file under downloads when publishing. This builds the Leaders download from the extension directory with permission for the ward’s exact host. The bundled placeholder has no access to an actual ward site.
5. For meeting-request email alerts, follow the instructions linked in Leaders settings. For optional Google Sheets and announcement publishing, customize scripts/announcements.gs with your own repository, sheet IDs, site URL, calendar name and time zone before deploying it to Apps Script.

## File layout

- Root HTML, CSS and JavaScript implement the site. website-privacy.html and website-terms.html are the policies linked from the footer.
- announcements.json and calendar.ics are valid empty starting files. Publishing fills them with ward content.
- extension contains editable Chrome extension source. downloads contains the ZIP served to leaders.
- scripts contains integration code and manual import tools. supabase contains database definitions and incremental changes.
- vendor contains the PDF libraries, fonts and their accompanying notices.

Keep private exports and deployment credentials outside the public repository.
