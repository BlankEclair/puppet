# This is the VCL file for Varnish, adjusted for Miraheze's needs.
# It was originally written by Southparkfan in 2015, but rewritten in 2022 by John.
# Some material used is inspired by the Wikimedia Foundation's configuration files.
# Their material and license is available at https://github.com/wikimedia/puppet

# Marker to tell the VCL compiler that this VCL has been adapted to the
# new 4.1 format.
vcl 4.1;

// Includes for Exp cache admission policy, admission probability exponentially
// decreasing with size. See mf_admission_policies.
C{
   #include <stdlib.h>
   #include <math.h>
   #include <errno.h>

   #define RATE 0.2
   #define BASE -20.3
   #define MEMORY <%= @v_mem_gb.to_i/1024.0 %>
   const double adm_param = pow(MEMORY, RATE) / pow(2.0, BASE);
}C

# Import some modules used
import directors;
import std;
import vsthrottle;

# MediaWiki configuration
probe mwhealth {
	.request = "GET /check HTTP/1.1"
		"Host: health.miraheze.org"
		"User-Agent: Varnish healthcheck"
		"Connection: close";
	# Check each <%= @interval_check %>
	.interval = <%= @interval_check %>;
	# <%= @interval_timeout %> should be our upper limit for responding to a fair light web request
	.timeout = <%= @interval_timeout %>;
	# At least 4 out of 5 checks must be successful
	# to mark the backend as healthy
	.window = 5;
	.threshold = 4;
	.initial = 4;
	.expected_response = 204;
}

<%- @backends.each_pair do | name, property | -%>
backend <%= name %> {
	.host = "localhost";
	.port = "<%= property['port'] %>";
<%- if property['probe'] -%>
	.probe = <%= property['probe'] %>;
<%- end -%>
}
<%- end -%>

# Initialise vcl
sub vcl_init {
	new mediawiki = directors.random();
<%- @backends.each_pair do | name, property | -%>
<%- if property['pool'] -%>
	mediawiki.add_backend(<%= name %>, 1);
<%- end -%>
<%- end -%>
}

# Purge ACL
acl purge {
	"localhost";
	# IPv6
	"2a10:6740::/64";
	# IPv4
	"31.24.105.128/28";
}

acl miraheze_nets {
	# IPv6
	"2a10:6740::/64";
	# IPv4
	"31.24.105.128/28";
}

# Cookie handling logic
sub evaluate_cookie {
	# Replace all session/token values with a non-unique global value for caching purposes.
	if (req.restarts == 0) {
		unset req.http.X-Orig-Cookie;
		if (req.http.Cookie) {
			set req.http.X-Orig-Cookie = req.http.Cookie;
			if (req.http.Cookie ~ "([sS]ession|Token)=") {
				set req.http.Cookie = "Token=1";
			} else {
				unset req.http.Cookie;
			}
		}
	}
}

# Mobile detection logic
sub mobile_detection {
	# If the User-Agent matches the regex (this is the official regex used in MobileFrontend for automatic device detection), 
	# and the cookie does NOT explicitly state the user does not want the mobile version, we
	# set X-Device to phone-tablet. This will make vcl_backend_fetch add ?useformat=mobile to the URL sent to the backend.
	if (req.http.User-Agent ~ "(?i)(mobi|240x240|240x320|320x320|alcatel|android|audiovox|bada|benq|blackberry|cdm-|compal-|docomo|ericsson|hiptop|htc[-_]|huawei|ipod|kddi-|kindle|meego|midp|mitsu|mmp\/|mot-|motor|ngm_|nintendo|opera.m|palm|panasonic|philips|phone|playstation|portalmmm|sagem-|samsung|sanyo|sec-|semc-browser|sendo|sharp|silk|softbank|symbian|teleca|up.browser|vodafone|webos)" && req.http.Cookie !~ "(stopMobileRedirect=true|mf_useformat=desktop)") {
		set req.http.X-Device = "phone-tablet";

		# In vcl_backend_fetch we'll decide in which situations we should actually do something with this.
		set req.http.X-Use-Mobile = "1";
	} else {
		set req.http.X-Device = "desktop";
	}
}

# Rate limiting logic
sub rate_limit {
	# Allow higher limits for static.miraheze.org, we can handle more of those requests
	if (req.http.Host == "static.miraheze.org") {
		if (vsthrottle.is_denied("static:" + req.http.X-Real-IP, 1000, 1s)) {
			return (synth(429, "Varnish Rate Limit Exceeded"));
		}
	} else {
		// Ratelimit miss/pass requests per IP:
		//   * Excluded for now:
		//       * all MF IPs
		//       * T6283: remove rate limit for IABot (temporarily?)
		//       * seemingly-authenticated requests (simple cookie check)
		//   * MW rest.php and MW API, Wikidata: 1000/10s (100/s long term, with 1000 burst)
		//   * All others (excludes static): 1000/50s (20/s long term, with 1000 burst)
		if (
			req.http.Cookie !~ "([sS]ession|Token)=" &&
			std.ip(req.http.X-Real-IP, "192.0.2.1") !~ miraheze_nets &&
			(req.http.X-Real-IP != "185.15.56.22" && req.http.User-Agent !~ "^IABot/2")
		) {
			if (req.url ~ "^/(w/api.php|w/rest.php|wiki/Special:EntityData)") {
				if (vsthrottle.is_denied("rest:" + req.http.X-Real-IP, 1000, 10s)) {
					return (synth(429, "Too Many Requests"));
				}
			} else {
				if (vsthrottle.is_denied("mwrtl:" + req.http.X-Real-IP, 1000, 50s)) {
					return (synth(429, "Too Many Requests"));
				}
			}
		}
	}
}

# Artificial error handling/redirects within Varnish
sub vcl_synth {
	if (req.method != "PURGE") {
		set resp.http.X-CDIS = "int";

		if (resp.status == 752) {
			set resp.http.Location = resp.reason;
			set resp.status = 302;
			return (deliver);
		}
	
		// Homepage redirect to commons
		if (resp.reason == "Commons Redirect") {
			set resp.reason = "Moved Permanently";
			set resp.http.Location = "https://commons.miraheze.org/";
			set resp.http.Connection = "keep-alive";
			set resp.http.Content-Length = "0";
		}
	
		// Handle CORS preflight requests
		if (
			req.http.Host == "static.miraheze.org" &&
			resp.reason == "CORS Preflight"
		) {
			set resp.reason = "OK";
			set resp.http.Connection = "keep-alive";
			set resp.http.Content-Length = "0";
	
			// allow Range requests, and avoid other CORS errors when debugging with X-Miraheze-Debug
			set resp.http.Access-Control-Allow-Origin = "*";
			set resp.http.Access-Control-Allow-Headers = "Range,X-Miraheze-Debug";
			set resp.http.Access-Control-Allow-Methods = "GET, HEAD, OPTIONS";
			set resp.http.Access-Control-Max-Age = "86400";
		} else {
			call add_upload_cors_headers;
		}
	}
}

# Purge Handling
sub recv_purge {
	if (req.method == "PURGE") {
		if (!client.ip ~ purge) {
			return (synth(405, "Denied."));
		} else {
			return (purge);
		}
	}
}

# Main MediaWiki Request Handling
sub mw_request {
	call rate_limit;
	call mobile_detection;
	
	# Assigning a backend
<%- @backends.each_pair do | name, property | -%>
	if (req.http.X-Miraheze-Debug == "<%= name %>.miraheze.org") {
		set req.backend_hint = <%= name %>;
		return (pass);
	}
<%- end -%>

	set req.backend_hint = mediawiki.backend();

	# Rewrite hostname to static.miraheze.org for caching
	if (req.url ~ "^/static/") {
		set req.http.Host = "static.miraheze.org";
	}

	# Numerous static.miraheze.org specific code
	if (req.http.Host == "static.miraheze.org") {
		unset req.http.X-Range;

		if (req.http.Range) {
			set req.hash_ignore_busy = true;
		}

		# We can do this because static.miraheze.org should not be capable of serving such requests anyway
		# This could also increase cache hit rates as Cookies will be stripped entirely
		unset req.http.Cookie;
		unset req.http.Authorization;

		# CORS Prelight
		if (req.method == "OPTIONS" && req.http.Origin) {
			return (synth(200, "CORS Preflight"));
		}

		# From Wikimedia: https://gerrit.wikimedia.org/r/c/operations/puppet/+/120617/7/templates/varnish/upload-frontend.inc.vcl.erb
		# required for Extension:MultiMediaViewer: T10285
		if (req.url ~ "(?i)(\?|&)download(=|&|$)") {
			set req.http.X-Content-Disposition = "attachment";
		}

		// Strip away all query parameters
		set req.url = regsub(req.url, "\?.*$", "");
		
		// Replace double slashes
		set req.url = regsuball(req.url, "/{2,}", "/");

		// Thumb fixups
		if (req.url ~ "(?i)/thumb/") {
			// Normalize end of thumbnail URL (redundant filename)
			// Lowercase last part of the URL, to avoid case variations on extension or thumbnail parameters
			// eg. /metawiki/thumb/0/06/Foo.jpg/120px-FOO.JPG => /metawiki/thumb/0/06/Foo.jpg/120px-foo.jpg
			set req.url = regsub(req.url, "^(.+/)[^/]+$", "\1") + std.tolower(regsub(req.url, "^.+/([^/]+)$", "\1"));

			// Copy canonical filename from beginning of URL to thumbnail parameters at the end
			// eg. /metawiki/thumb/0/06/Foo.jpg/120px-bar.jpg => /metawiki/thumb/0/06/Foo.jpg/120px-Foo.jpg.jpg
			set req.url = regsub(req.url, "/([^/]+)/((?:qlow-)?(?:lossy-)?(?:lossless-)?(?:page\d+-)?(?:lang[0-9a-z-]+-)?\d+px-(?:(?:seek=|seek%3d)\d+-)?)[^/]+\.(\w+)$", "/\1/\2\1.\3");

			// Last pass, clean up any redundant extension
			// .jpg.jpg => .jpg, .JPG.jpg => .JPG
			// eg. /metawiki/thumb/0/06/Foo.jpg/120px-Foo.jpg.jpg => /metawiki/thumb/0/06/Foo.jpg/120px-Foo.jpg
			if (req.url ~ "(?i)(.*)(\.\w+)\2$") {
				set req.url = regsub(req.url, "(?i)(.*)(\.\w+)\2$", "\1\2");
			}
		}

		// Fixup borked client Range: headers
		if (req.http.Range ~ "(?i)bytes:") {
			set req.http.Range = regsub(req.http.Range, "(?i)bytes:\s*", "bytes=");
		}
	}

	# If a user is logged out, do not give them a cached page of them logged in
	if (req.http.If-Modified-Since && req.http.Cookie ~ "LoggedOut") {
		unset req.http.If-Modified-Since;
	}

	# Don't cache a non-GET or HEAD request
	if (req.method != "GET" && req.method != "HEAD") {
		# Zero reason to append ?useformat=true here
		set req.http.X-Use-Mobile = "0";
		return (pass);
	}

	# Do not cache dumps and also pipe requests.
	if ( req.http.Host == "static.miraheze.org" && req.url ~ "^/.*wiki/dumps" ) {
		return (pipe);
	}

	# Don't cache certain things on static
	if (
		req.http.Host == "static.miraheze.org" &&
		(
			req.url !~ "^/.*wiki" || # If it isn't a wiki folder, don't cache it
			req.url ~ "^/(.+)wiki/sitemaps" # Do not cache sitemaps
		)
	) {
		return (pass);
	}

	# We can rewrite those to one domain name to increase cache hits
	if (req.url ~ "^/w/(skins|resources|extensions)/" ) {
		set req.http.Host = "meta.miraheze.org";
	}

	call evaluate_cookie;

	if (req.url ~ "^/w/rest.php/.*" ) {
		return (pass);
	}

	# A requet via OAuth should not be cached or use a cached response elsewhere
	if (req.http.Authorization ~ "OAuth") {
		return (pass);
	}

	if (req.http.Authorization ~ "^OAuth ") {
		return (pass);
	}
}

# Initial sub route executed on a Varnish request, the heart of everything
sub vcl_recv {
	call recv_purge; # Check purge

	unset req.http.Proxy; # https://httpoxy.org/

	unset req.http.X-CDIS;

	# Health checks, do not send request any further, if we're up, we can handle it
	if (req.http.Host == "health.miraheze.org" && req.url == "/check") {
		return (synth(200));
	}
	
	if (req.http.host == "static.miraheze.org" && req.url == "/") {
		return (synth(301, "Commons Redirect"));
	}

	if (
		req.url ~ "^/\.well-known" ||
		req.http.Host == "ssl.miraheze.org" ||
		req.http.Host == "acme.miraheze.org"
	) {
		set req.backend_hint = puppet141;
		return (pass);
	}

	if (req.http.Host ~ "^(.*\.)?betaheze\.org") {
		set req.backend_hint = test131;
		return (pass);
	}

	# Only cache js files from Matomo
	if (req.http.Host == "matomo.miraheze.org") {
		set req.backend_hint = matomo121;

		# Yes, we only care about this file
		if (req.url ~ "^/piwik.js" || req.url ~ "^/matomo.js") {
			return (hash);
		} else {
			return (pass);
		}
	}

	# Do not cache requests from this domain
	if (req.http.Host == "icinga.miraheze.org" || req.http.Host == "grafana.miraheze.org") {
		set req.backend_hint = mon141;

		if (req.http.upgrade ~ "(?i)websocket") {
			return (pipe);
		}

		return (pass);
	}

	# Do not cache requests from this domain
	if (req.http.Host == "phabricator.miraheze.org" || req.http.Host == "phab.miraheze.wiki" ||
		req.http.Host == "blog.miraheze.org") {
		set req.backend_hint = phab121;
		return (pass);
	}

	# Do not cache requests from this domain
	if (req.http.Host == "webmail.miraheze.org") {
		set req.backend_hint = mail121;
		return (pass);
	}

	# Do not cache requests from this domain
	if (req.http.Host == "reports.miraheze.org") {
		set req.backend_hint = reports121;
		return (pass);
	}

	# MediaWiki specific
	call mw_request;

	return (hash);
}

# Defines the uniqueness of a request
sub vcl_hash {
	# FIXME: try if we can make this ^/wiki/ only?
	if (req.url ~ "^/wiki/" || req.url ~ "^/w/load.php") {
		hash_data(req.http.X-Device);
	}
}

sub vcl_pipe {
	// for websockets over pipe
	if (req.http.upgrade) {
		set bereq.http.upgrade = req.http.upgrade;
		set bereq.http.connection = req.http.connection;
	}
}

# Initiate a backend fetch
sub vcl_backend_fetch {
	# Modify the end of the URL if mobile device
	if ((bereq.url ~ "^/wiki/[^$]" || bereq.url ~ "^/w/index.php(.*)title=[^$]") && bereq.http.X-Device == "phone-tablet" && bereq.http.X-Use-Mobile == "1") {
		if (bereq.url ~ "\?") {
			set bereq.url = bereq.url + "&useformat=mobile";
		} else {
			set bereq.url = bereq.url + "?useformat=mobile";
		}
	}
	
	# Restore original cookies
	if (bereq.http.X-Orig-Cookie) {
		set bereq.http.Cookie = bereq.http.X-Orig-Cookie;
		unset bereq.http.X-Orig-Cookie;
	}

	if (bereq.http.X-Range) {
		set bereq.http.Range = bereq.http.X-Range;
		unset bereq.http.X-Range;
	}
}

sub mf_admission_policies {
    // hit-for-pass objects >= 8388608 size. Do cache if Content-Length is missing.
    if (bereq.http.Host == "static.miraheze.org" && std.integer(beresp.http.Content-Length, 0) >= 8388608) {
        // HFP
        set beresp.http.X-CDIS = "pass";
        return(pass(beresp.ttl));
    }

    // hit-for-pass objects >= 67108864 size. Do cache if Content-Length is missing.
    if (bereq.http.Host != "static.miraheze.org" && std.integer(beresp.http.Content-Length, 0) >= 67108864) {
        // HFP
        set beresp.http.X-CDIS = "pass";
        return(pass(beresp.ttl));
    }

if (bereq.http.Host == "static.miraheze.org" && beresp.status == 200 && bereq.http.X-CDIS == "miss") {
C{
   const struct gethdr_s hdr = { HDR_BERESP, "\017Content-Length:" };
   const char *clen_hdr = VRT_GetHdr(ctx, &hdr);
   // Set CL:0 by default
   unsigned long int clen = 0;

   // If Content-Length has been specified
   if (clen_hdr) {
       errno = 0;
       clen = strtoul(clen_hdr, NULL, 10);
       if (errno)
           clen = 0;
   }

   if (clen) {
       const double clen_neg = -1.0 * (double)clen;
       const double admissionprob = exp(clen_neg/adm_param);
       const double urand = drand48();

       // If admission test succeeds, mark as uncacheable
       if (admissionprob < urand) {
           // HFM with ttl=67 to avoid stalling
           VRT_l_beresp_ttl(ctx,67);
           VRT_l_beresp_uncacheable(ctx,1);
       }
    }
}C
}

    return (deliver);
}

# Backend response, defines cacheability
sub vcl_backend_response {
	// This prevents the application layer from setting this in a response.
	// We'll be setting this same variable internally in VCL in hit-for-pass
	// cases later.
	unset beresp.http.X-CDIS;

	if (bereq.http.Cookie ~ "([sS]ession|Token)=") {
		set bereq.http.Cookie = "Token=1";
	} else {
		unset bereq.http.Cookie;
	}

	if (beresp.http.Content-Range) {
		// Varnish itself doesn't ask for ranges, so this must have been
		// a passed range request
		set beresp.http.X-Content-Range = beresp.http.Content-Range;
	}

	# T9808: Assign restrictive Cache-Control if one is missing
	if (!beresp.http.Cache-Control) {
		set beresp.http.Cache-Control = "private, s-maxage=0, max-age=0, must-revalidate";
		set beresp.ttl = 0s;
		// translated to hit-for-pass below
	}

	/* Don't cache private, no-cache, no-store objects. */
	if (beresp.http.Cache-Control ~ "(?i:private|no-cache|no-store)") {
		set beresp.ttl = 0s;
		// translated to hit-for-pass below
	}

	/* Especially don't cache Set-Cookie responses. */
	if ((beresp.ttl > 0s || beresp.http.Cache-Control ~ "public") && beresp.http.Set-Cookie) {
		set beresp.ttl = 0s;
		// translated to hit-for-pass below
	}
	// Set a maximum cap on the TTL for 404s. Objects that don't exist now may
	// be created later on, and we want to put a limit on the amount of time
	// it takes for new resources to be visible.
	elsif (beresp.status == 404 && beresp.ttl > 10m) {
		set beresp.ttl = 10m;
	}

	# Cookie magic as we did before
	if (bereq.http.Cookie ~ "([Ss]ession|Token)=") {
		set bereq.http.Cookie = "Token=1";
	} else {
		unset bereq.http.Cookie;
	}

	# Do not cache a backend response if HTTP code is above 400, except a 404, then limit TTL
	if (beresp.status >= 400 && beresp.status != 404) {
		set beresp.uncacheable = true;
	} elseif (beresp.status == 404 && beresp.ttl > 10m) {
		set beresp.ttl = 10m;
	}

    // Set keep, which influences the amount of time objects are kept available
    // in cache for IMS requests (TTL+grace+keep). Scale keep to the app-provided
    // TTL.
	if (beresp.ttl > 0s) {
		if (beresp.http.ETag || beresp.http.Last-Modified) {
			if (beresp.ttl < 1d) {
				set beresp.keep = beresp.ttl;
			} else {
				set beresp.keep = 1d;
			}
		}

		// Hard TTL cap on all fetched objects (default 1d)
		if (beresp.ttl > 1d) {
			set beresp.ttl = 1d;
		}

		set beresp.grace = 20m;
	}

	# Distribute caching re-calls where possible
	if (beresp.ttl >= 60s) {
		set beresp.ttl = beresp.ttl * std.random( 0.95, 1.00 );
	}

	if (beresp.http.Set-Cookie) {
		set beresp.uncacheable = true; # We do this just to be safe - but we should probably log this to eliminate it?
	}

	# Cache 301 redirects for 12h (/, /wiki, /wiki/ redirects only)
	if (beresp.status == 301 && bereq.url ~ "^/?(wiki/?)?$" && !beresp.http.Cache-Control ~ "no-cache") {
		set beresp.ttl = 43200s;
	}

	# Cache non-modified robots.txt for 12 hours, otherwise 5 minutes
	if (bereq.url == "/robots.txt") {
		if (beresp.http.X-Miraheze-Robots == "Custom") {
			set beresp.ttl = 300s;
		} else {
			set beresp.ttl = 43200s;
		}
	}

	// Compress compressible things if the backend didn't already, but
	// avoid explicitly-defined CL < 860 bytes.  We've seen varnish do
	// gzipping on CL:0 302 responses, resulting in output that has CE:gzip
	// and CL:20 and sends a pointless gzip header.
	// Very small content may actually inflate from gzipping, and
	// sub-one-packet content isn't saving a lot of latency for the gzip
	// costs (to the server and the client, who must also decompress it).
	// The magic 860 number comes from Akamai, Google recommends anywhere
	// from 150-1000.  See also:
	// https://webmasters.stackexchange.com/questions/31750/what-is-recommended-minimum-object-size-for-gzip-performance-benefits
	if (beresp.http.content-type ~ "json|text|html|script|xml|icon|ms-fontobject|ms-opentype|x-font|sla"
		&& (!beresp.http.Content-Length || std.integer(beresp.http.Content-Length, 0) >= 860)) {
			set beresp.do_gzip = true;
	}
	// SVGs served by MediaWiki are part of the interface. That makes them
	// very hot objects, as a result the compression time overhead is a
	// non-issue. Several of them tend to be requested at the same time,
	// as the browser finds out about them when parsing stylesheets that
	// contain multiple. This means that the "less than 1 packet" rationale
	// for not compressing very small objects doesn't apply either. Lastly,
	// since they're XML, they contain a fair amount of repetitive content
	// even when small, which means that gzipped SVGs tend to be
	// consistantly smaller than their uncompressed version, even when tiny.
	// For all these reasons, it makes sense to have a lower threshold for
	// SVG. Applying it to XML in general is a more unknown tradeoff, as it
	// would affect small API responses that are more likely to be cold
	// objects due to low traffic to specific API URLs.
	if (beresp.http.content-type ~ "svg" && (!beresp.http.Content-Length || std.integer(beresp.http.Content-Length, 0) >= 150)) {
		set beresp.do_gzip = true;
	}

	// set a 601s hit-for-pass object based on response conditions in vcl_backend_response:
	//    Calculated TTL <= 0 + Status < 500:
	//    These are generally uncacheable responses.  The 5xx exception
	//    avoids us accidentally replacing a good stale/grace object with
	//    an hfp (and then repeatedly passing on potentially-cacheable
	//    content) due to an isolated 5xx response.
	if (beresp.ttl <= 0s && beresp.status < 500 && (!beresp.http.X-Cache-Int || beresp.http.X-Cache-Int !~ "hit")) {
		set beresp.grace = 31s;
		set beresp.keep = 0s;
		set beresp.http.X-CDIS = "pass";
		return(pass(601s));
	}

	// It is important that this happens after the code responsible for translating TTL<=0
	// (uncacheable) responses into hit-for-pass.
	call mf_admission_policies;

	// return (deliver);
}

# Last sub route activated, clean up of HTTP headers etc.
sub vcl_deliver {
	if (req.method != "PURGE") {
		// we copy through from beresp->resp->req here for the initial hit-for-pass case
		if (resp.http.X-CDIS) {
			set req.http.X-CDIS = resp.http.X-CDIS;
			unset resp.http.X-CDIS;
		}

		if (!req.http.X-CDIS) {
			set req.http.X-CDIS = "bug";
		}
	}

	// Provides custom error html if error response has no body
	if (resp.http.Content-Length == "0" && resp.status >= 400) {
		return(synth(resp.status));
	}

	if (resp.http.X-Content-Range) {
		set resp.http.Content-Range = resp.http.X-Content-Range;
		unset resp.http.X-Content-Range;
	}

	if ( req.http.Host == "static.miraheze.org" ) {
		unset resp.http.Set-Cookie;
		unset resp.http.Cache-Control;

		if (req.http.X-Content-Disposition == "attachment") {
			set resp.http.Content-Disposition = "attachment";
		}

		// Prevent browsers from content sniffing.
		set resp.http.X-Content-Type-Options = "nosniff";

		call add_upload_cors_headers;
	}

	if ( req.url ~ "^(?i)\/w\/img_auth\.php\/(.+)" ) {
		call add_upload_cors_headers;
	}

	if (req.url ~ "^/wiki/" || req.url ~ "^/w/index\.php") {
		// ...but exempt CentralNotice banner special pages
		if (req.url !~ "^/(wiki/|w/index\.php\?title=)Special:Banner") {
			set resp.http.Cache-Control = "private, s-maxage=0, max-age=0, must-revalidate";
		}
	}

	# Client side caching for load.php
	if (req.url ~ "^/w/load\.php" ) {
		set resp.http.Age = 0;
	}

	# Do not index certain URLs
	if (req.url ~ "^(/w/(api|index|rest)\.php*|/wiki/Special(\:|%3A)(?!WikiForum)).+$") {
		set resp.http.X-Robots-Tag = "noindex";
	}

	# Disable Google ad targeting (FLoC)
	set resp.http.Permissions-Policy = "interest-cohort=(), browsing-topics=()";

	# Content Security Policy
	set resp.http.Content-Security-Policy = "<%- @csp.each_pair do |type, value| -%> <%= type %> <%= value.join(' ') %>; <%- end -%>";

	# For a 500 error, do not set cookies
	if (resp.status >= 500 && resp.http.Set-Cookie) {
		unset resp.http.Set-Cookie;
	}

	# Set X-Cache from request
	set resp.http.X-Cache = req.http.X-Cache;

	# Identify uncacheable content
	if (obj.uncacheable) {
		set resp.http.X-Cache = resp.http.X-Cache + " UNCACHEABLE";
	}

	if (req.http.X-Content-Disposition == "attachment") {
		set resp.http.Content-Disposition = "attachment";
	}

	return (deliver);
}

sub add_upload_cors_headers {
	set resp.http.Access-Control-Allow-Origin = "*";

	// Headers exposed for CORS:
	// - Age, Content-Length, Date, X-Cache
	//
	// - X-Content-Duration: used for OGG audio and video files.
	//   Firefox 41 dropped support for this header, but OGV.js still supports it.
	//   See <https://bugzilla.mozilla.org/show_bug.cgi?id=1160695#c27> and
	//   <https://github.com/brion/ogv.js/issues/88>.
	//
	// - Content-Range: indicates total file and actual range returned for RANGE
	//   requests. Used by ogv.js to eliminate an extra HEAD request
	//   to get the total file size.
	set resp.http.Access-Control-Expose-Headers = "Age, Date, Content-Length, Content-Range, X-Content-Duration, X-Cache";
}

# Hit code, default logic is appended
sub vcl_hit {
	set req.http.X-CDIS = "hit";

	# Add X-Cache header
	set req.http.X-Cache = "<%= @facts['networking']['hostname'] %> HIT (" + obj.hits + ")";

	# Is the request graced?
	if (obj.ttl <= 0s && obj.grace > 0s) {
		set req.http.X-Cache = req.http.X-Cache + " GRACE";
	}
}

# Miss code, default logic is appended
sub vcl_miss {
	set req.http.X-CDIS = "miss";

	# Add X-Cache header
	set req.http.X-Cache = "<%= @facts['networking']['hostname'] %> MISS";

    // Convert range requests into pass
    if (req.http.Range) {
        // Varnish strips the Range header before copying req into bereq. Save it into
        // a header and restore it in vcl_backend_fetch
        set req.http.X-Range = req.http.Range;
        return (pass);
    }
}

# Pass code, default logic is appended
sub vcl_pass {
	set req.http.X-CDIS = "pass";

	# Add X-Cache header
	set req.http.X-Cache = "<%= @facts['networking']['hostname'] %> PASS";
}

# Synthetic code, default logic is appended
sub vcl_synth {
	# Add X-Cache header
	set req.http.X-Cache = "<%= @facts['networking']['hostname'] %> SYNTH";
}

# Backend response when an error occurs
sub vcl_backend_error {
	set beresp.http.Content-Type = "text/html; charset=utf-8";

	synthetic( {"<!DOCTYPE html>
	<html lang="en">
		<head>
			<meta charset="utf-8" />
			<meta name="viewport" content="width=device-width, initial-scale=1.0" />
			<meta name="description" content="Backend Fetch Failed" />
			<title>"} + beresp.status + " " + beresp.reason + {"</title>
			<!-- Bootstrap core CSS -->
			<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@4.6.0/dist/css/bootstrap.min.css" integrity="sha384-B0vP5xmATw1+K9KRQjQERJvTumQW0nPEzvF6L/Z6nronJ3oUOFUFpCjEUQouq2+l" crossorigin="anonymous"/>
			<style>
				/* Error Page Inline Styles */
				body {
					padding-top: 20px;
				}
				/* Layout */
				.jumbotron {
					font-size: 21px;
					font-weight: 200;
					line-height: 2.1428571435;
					color: inherit;
					padding: 10px 0px;
					text-align: center;
					background-color: transparent;
				}
				/* Everything but the jumbotron gets side spacing for mobile-first views */
				.body-content {
					padding-left: 15px;
					padding-right: 15px;
				}
				/* button */
				.jumbotron .btn {
					font-size: 21px;
					padding: 14px 24px;
				}
				/* Fade-in */
				@keyframes fadein {
					from { opacity: 0; }
					to   { opacity: 1; }
				}
				/* Dark mode */
				@media (prefers-color-scheme: dark) {
					body {
						background-color: #282828;
						color: white;
					}
					h1, h2, p {
						color: white;
					}
				}
			</style>
		</head>
		<div class="container">
			<!-- Jumbotron -->
			<div class="jumbotron">
				<p style="font-align: center; animation: fadein 1s;"><?xml version="1.0" encoding="UTF-8" standalone="no"?><svg id="svg4206" version="1.1" inkscape:version="1.2.1 (9c6d41e410, 2022-07-14)" width="130.851" height="134.98416" viewBox="0 0 130.851 134.98416" sodipodi:docname="mhwarn.svg" xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape" xmlns:sodipodi="http://sodipodi.sourceforge.net/DTD/sodipodi-0.dtd" xmlns="http://www.w3.org/2000/svg" xmlns:svg="http://www.w3.org/2000/svg" xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:cc="http://creativecommons.org/ns#" xmlns:dc="http://purl.org/dc/elements/1.1/"><defs id="defs4210" /> <sodipodi:namedview pagecolor="#ffffff" bordercolor="#666666" borderopacity="1" objecttolerance="10" gridtolerance="10" guidetolerance="10" inkscape:pageopacity="0" inkscape:pageshadow="2" inkscape:window-width="1920" inkscape:window-height="1009" id="namedview4208" showgrid="true" fit-margin-top="0" fit-margin-left="0" fit-margin-right="0" fit-margin-bottom="0" inkscape:zoom="4.0163665" inkscape:cx="99.343524" inkscape:cy="87.890385" inkscape:window-x="-8" inkscape:window-y="-8" inkscape:window-maximized="1" inkscape:current-layer="svg4206" showborder="false" inkscape:showpageshadow="2" inkscape:pagecheckerboard="0" inkscape:deskcolor="#d1d1d1"> <inkscape:grid type="xygrid" id="grid4863" originx="-29.149001" originy="-23.271838" /> </sodipodi:namedview> <path style="fill:#8e7650;fill-opacity:1;fill-rule:evenodd;stroke:none;stroke-width:1px;stroke-linecap:butt;stroke-linejoin:miter;stroke-opacity:1" d="m 52.721681,48.525706 21.189606,0.06232 10.968739,18.946003 -10.84409,18.696711 H 52.659356 L 41.752943,67.471705 Z" id="path4756" inkscape:connector-curvature="0" /> <path style="fill:#ffc200;fill-opacity:1;fill-rule:evenodd;stroke:none;stroke-width:1px;stroke-linecap:butt;stroke-linejoin:miter;stroke-opacity:1" d="M 52.7219,0 73.911507,0.06233 84.880246,19.008333 74.036156,37.705042 H 52.659576 L 41.753162,18.946004 Z" id="path4756-4" inkscape:connector-curvature="0" /> <path style="fill:#ffc200;fill-opacity:1;fill-rule:evenodd;stroke:none;stroke-width:1px;stroke-linecap:butt;stroke-linejoin:miter;stroke-opacity:1" d="m 52.7219,97.279112 21.189607,0.06233 10.968739,18.946008 -10.84409,18.69671 H 52.659576 L 41.753162,116.22513 Z" id="path4756-4-7" inkscape:connector-curvature="0" inkscape:transform-center-x="23.96383" inkscape:transform-center-y="-86.164066" /> <path style="fill:#ffc200;fill-opacity:1;fill-rule:evenodd;stroke:none;stroke-width:1px;stroke-linecap:butt;stroke-linejoin:miter;stroke-opacity:1" d="m 94.666356,24.313311 21.189604,0.06232 10.96874,18.946001 -10.84409,18.696715 H 94.604032 L 83.697618,43.259317 Z" id="path4756-4-7-0-4" inkscape:connector-curvature="0" inkscape:transform-center-x="23.963831" inkscape:transform-center-y="-86.164068" /> <path style="fill:#ffc200;fill-opacity:1;fill-rule:evenodd;stroke:none;stroke-width:1px;stroke-linecap:butt;stroke-linejoin:miter;stroke-opacity:1" d="m 10.946578,24.313315 21.1464,0.06232 10.94636,18.945997 -10.821965,18.696715 H 10.884381 L 2.04e-4,43.259317 Z" id="path4756-4-7-0-4-0" inkscape:connector-curvature="0" inkscape:transform-center-x="23.914978" inkscape:transform-center-y="-86.164069" /> <path style="fill:#ffc200;fill-opacity:1;fill-rule:evenodd;stroke:none;stroke-width:1px;stroke-linecap:butt;stroke-linejoin:miter;stroke-opacity:1" d="M 10.968739,72.678425 32.158346,72.740745 43.12708,91.686749 32.282994,110.38347 H 10.906415 L 0,91.624434 Z" id="path4756-4-7-0-4-5" inkscape:connector-curvature="0" inkscape:transform-center-x="23.96383" inkscape:transform-center-y="-86.16407" /> <path d="M 92.925494,56.217561 A 37.925497,37.925497 0 1 0 130.851,94.143056 37.925497,37.925497 0 0 0 92.925494,56.217561 Z m 3.792549,60.680789 h -7.5851 v -7.58509 h 7.5851 z m 0,-15.17019 h -7.5851 V 71.387759 h 7.5851 z" id="path4" style="fill:#ff5d00;fill-opacity:1;stroke-width:3.79255" /></svg></p>
				<h1>"} + beresp.status + " " + beresp.reason + {"</h1>
				<p class="lead">Try again later or click the button below to refresh.</p>
				<p style="font-size: 70%; margin: -1em;">If you were trying to import something and encountered this error, use <a href="https://meta.miraheze.org/wiki/Special:RequestImportDump">ImportDump</a> instead.</p><br />
				<a href="javascript:document.location.reload(true);" class="btn btn-lg btn-outline-success" role="button">Refresh page</a>
			</div>
		</div>
		<div class="container">
			<div class="body-content">
				<div class="row">
					<div class="col-md-6">
						<h2>What can I do?</h2>
						<p>Please try again in a few minutes. If the problem persists, please report this on <a href="https://phabricator.miraheze.org">Phabricator</a> or join our <a href="https://discord.gg/TVAJTE4CUn">Discord server</a> or IRC channel (<a href="https://web.libera.chat/?channel=#miraheze-sre">#miraheze-sre</a>) for additional updates. We apologise for the inconvenience. Our Site Reliability Engineers are working to correct the issue.</p>
					</div>
					<div class="col-md-6">
						<a class="twitter-timeline" data-width="500" data-height="350" href="https://twitter.com/MirahezeStatus?ref_src=twsrc%5Etfw">Tweets by MirahezeStatus</a> <script async src="https://platform.twitter.com/widgets.js" charset="utf-8"></script>
					</div>
				</div>
			</div>
		</div>

		<div class="footer">
			<div class="text-center">
				<p class="lead">When reporting this, please include the information below:</p>

				Error "} + beresp.status + " " + beresp.reason + {", forwarded for "} + bereq.http.X-Forwarded-For + {" <br />
				(Varnish XID "} + bereq.xid + {") via "} + server.identity + {" at "} + now + {".
				<br /><br />
			</div>
		</div>
	</html>
	"} );

	return (deliver);
}
