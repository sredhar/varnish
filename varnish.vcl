#
# This is a basic VCL configuration file for varnish.  See the vcl(7)
# man page for details on VCL syntax and semantics.
#
# Default backend definition.  Set this to point to your content
# server.
#
# Heavily borrowed settings from
# http://www.nedproductions.biz/wiki/a-perfected-varnish-reverse-caching-proxy-vcl-script
# https://www.varnish-cache.org/trac/wiki/VCLExampleAlexc
# http://technology.posterous.com/making-posterous-faster-with-varnish
# http://open.blogs.nytimes.com/2010/09/15/using-varnish-so-news-doesnt-break-your-server/
# http://pastie.org/2094138
#

## requires varnish 3.x

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Imports
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
import std;

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Probes
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
probe healthcheck {
    .url = "/robots.txt";
    .interval = 60s;
    .timeout = 60s;
    .window = 8;
    .threshold = 6;
    .initial = 3;
    .expected_response = 200;
}


# mysite-prd-web01
backend server1 {
  .host = "10.10.10.23";
  .port = "52021";
  .probe = healthcheck; 
  .first_byte_timeout = 300s;
} 

# mysite-prd-web02
backend server2 {
  .host = "10.10.10.24";
  .port = "52021";
  .probe = healthcheck;
  .first_byte_timeout = 300s;
}

# mysite-prd-web03
backend server3 {
  .host = "10.10.10.25";
  .port = "52021";
  .probe = healthcheck;
  .first_byte_timeout = 300s;
}


director vip_director round-robin {
    { .backend = server1; }
    { .backend = server2; }
    { .backend = server3; }
}

# Author can clear on publish
acl purge {
    "localhost";
    "10.10.10.23";
    "10.10.10.24";
    "10.10.10.25";
}

sub vcl_recv {
  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # Sets the default backend director
  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  set req.backend = vip_director;

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # Support incoming purge request from the ACL defined hosts
  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  if (req.request == "PURGE") {
    if (!client.ip ~ purge) {
      error 405 "Not allowed.";
    }
    return (lookup);
  }

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # Set grace based on the health of the backend
  # Read to understand: https://www.varnish-cache.org/trac/wiki/VCLExampleGrace
  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  if (req.backend.healthy) {
     set req.grace = 30s;
  }
  else {
     set req.grace = 1h;
  }

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # Ensure all request methods are conforming to HTTP spec
  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  if (req.request != "GET" &&
      req.request != "HEAD" &&
      req.request != "PUT" &&
      req.request != "POST" &&
      req.request != "TRACE" &&
      req.request != "OPTIONS" &&
      req.request != "DELETE") {
    ## Non-RFC2616 or CONNECT which is weird.
    return (pipe);
  }

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # Basic health check used by ELB
  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  if ( req.url == "/ping.html") {
    error 200 "OK";
  }

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # Ensure x-forwarded-for header is set correctly first
  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  if (req.http.x-forwarded-for) {
    set req.http.X-Forwarded-For = req.http.X-Forwarded-For + ", " + client.ip;
  }
  else {
    set req.http.X-Forwarded-For = client.ip;
  }

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # For request method that is not GET or HEAD, bypass the cache.
  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  if (req.request != "GET" && req.request != "HEAD") {
    return (pass);
  }

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # Redirect Rules before further processing
  # NOTE: No redirects implemented at this time.
  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # call vcl_recv_redirects;

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # For cached contents, fix gzip/deflate compression
  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  call vcl_recv_acceptencoding;

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # Cookie Handling, including specific URLs
  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  ## for any specific URL that should bypass cookie, adjust the subroutine
  call vcl_recv_nocache;

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # move to the next phase
  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  return (lookup);
}

sub vcl_pipe {
  ## If we don't set the Connection: close header, any following
  ## requests from the client will also be piped through and
  ## left untouched by varnish. We don't want that.
  set req.http.connection = "close";
  return(pipe);
}


# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# vcl_receive manages it so that only for GET/HEAD methods gets through.
# Non-Cacheable URL is filtered and bypassed during the vcl_receive phase
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
sub vcl_fetch {
  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # Handle no-store rules first
  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  call vcl_fetch_nocache;

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # Set grace based on the health of the backend
  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # NOT SURE IF NEEDED HERE!
  set beresp.grace = 1h;

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # Unset expires header and cookies
  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  ## Remove Expires from backend, it's not long enough
  unset beresp.http.expires;

  ## it's safe to strip out the cookies.  the valid cookies
  ## and no-cache rule should be applied above
  unset beresp.http.set-cookie;

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # Error Page TTL: Handle 404 and 500s caching strategy
  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  if (beresp.status >= 400) {
    call vcl_fetch_errorcache;
  }

  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # TTL per content type
  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  call vcl_fetch_cache;
}

sub vcl_deliver {
  if (resp.http.magicmarker) {
    ## Remove the magic marker
    unset resp.http.magicmarker;

    ## By definition we have a fresh object
    set resp.http.age = "0";
  }

  ## Add a header to indicate a cache HIT/MISS
  if (obj.hits > 0) {
    set resp.http.X-Cache = "HIT";
  }
  else {
    set resp.http.X-Cache = "MISS";
  }
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Default behavior
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
sub vcl_hit {
  if (req.request == "PURGE") {
    purge;
    error 200 "Purged.";
  }
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Default behavior
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
sub vcl_miss {
  if (req.request == "PURGE") {
    purge;
    error 200 "Purged.";
  }
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# gzip/deflate handling based on content type
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
sub vcl_recv_acceptencoding {
  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  # For cached contents, fix gzip/deflate compression
  # ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
  if (req.http.Accept-Encoding) {
    if (req.url ~ "\.(gif|jpg|jpeg|bmp|png|tiff|tif|ico|img|tga|wmf)$") {
      # No point in compressing these | matching the extensions for object caching
      remove req.http.Accept-Encoding;
    }
    else if (req.url ~ "\.(svg|swf|ico|mp3|mp4|m4a|ogg|mov|avi|wmv)$") {
      # No point in compressing these | matching the extensions for object caching
      remove req.http.Accept-Encoding;
    }
    else if (req.url ~ "\.(zip|gz|tgz|bz2|tbz)$") {
      # No point in compressing these
      remove req.http.Accept-Encoding;
    }
    else if (req.http.Accept-Encoding ~ "gzip") {
      set req.http.Accept-Encoding = "gzip";
    }
    else if (req.http.Accept-Encoding ~ "deflate") {
      set req.http.Accept-Encoding = "deflate";
    }
    else {
      ## unknown algorithm
      remove req.http.Accept-Encoding;
    }
  }
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# NO-STORE objects and cookie handling during vcl_recv phase
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
sub vcl_recv_nocache {
  if (req.http.Cookie) {
    # Don't remove cookie for /content/{sweeps,newsletters,polls,quizzes,contact,go,services,user,bin}.html
    if (req.url ~ "^/content/.*/(sweeps|newsletters|polls|quizzes|contact|go|services|user|bin).*\.html") {
      return (pass);
    }

    # WORDPRESS Specific - If on /wp-login or wp-admin or wordpress_logged_in_* cookie set, don't store.
    if ((req.url ~ "^/wp-(login|admin)") || (req.http.Cookie ~ "wordpress_logged_in_")) {
      return (pass);
    }

    ## strip all cookies
    remove req.http.Cookie;
  }

  ## If Authorization is set, we don't want to cache anything
  if (req.http.Authorization) {
    return (pass);
  }
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# NO-STORE objects during vcl_fetch phase
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
sub vcl_fetch_nocache {
  ## NO-STORE objects 
if (beresp.http.Cache-Control ~ "(no-cache|no-store|must-revalidate)") {
    set beresp.http.X-Cacheable = "NO:http.Cache-Control=" + beresp.http.Cache-Control;
    return (hit_for_pass);
  }

  ## Remove the Set-Cookie header for /content/{sweeps,newsletters,polls,quizzes,contact,go,services,user,bin}.html
  if (req.url ~ "^/content/.*/(sweeps|newsletters|polls|quizzes|contact|go|services|user|bin).*\.html") {
    set beresp.http.X-Cacheable = "NO:req.url=" + req.url;
    return (hit_for_pass);
  }

  ## Hit for Pass rules
  if (beresp.http.Vary == "*") {
    set beresp.http.X-Cacheable = "NO:beresp.http.Vary=" + beresp.http.Vary;
    return (hit_for_pass);
  }
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Caching rules for error statuses (i.e. TTL for 404 and 500)
# Only for status code >= 400
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
sub vcl_fetch_errorcache {
  ## 404 errors are cached briefly
  #if (beresp.status == 404) {
  #  if ( req.url ~ "^/news/articles" || req.url ~ "^/?article=" ) {
  #    ## Legacy Contents
  #    set beresp.ttl = 12h;
  #  }
  #  else {
  #    set beresp.ttl = 10s;
  #  }

  #  set beresp.http.cache-control = "public, max-age=" + beresp.ttl;
  #  set beresp.http.X-Cacheable   = "YES:Cache-Control=" + beresp.http.cache-control;
  #  return (deliver);
  #}

  ## 500 errors are cached briefly 
  #if (beresp.status >= 500) {
    ## 500+ errors
    #set beresp.ttl = 30s;

    #set beresp.http.cache-control = "public, max-age=" + beresp.ttl;
    #set beresp.http.X-Cacheable   = "YES:Cache-Control=" + beresp.http.cache-control;
    #return (deliver);
  #}

  ## for any other status codes, don't cache.
  if (beresp.status >= 400) {
    set beresp.http.X-Cacheable = "NO:beresp.status=" + beresp.status;
    return (hit_for_pass);
  }
}

# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# Regular Caching Rule based on content type
# This should be the last rule within vcl_fetch
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
sub vcl_fetch_cache {
  if (req.url ~ "\.(gif|jpg|jpeg|bmp|png|tiff|tif|ico|img|tga|wmf|txt|js|css|svg|swf|ico|mp3|mp4|m4q|ogg|mov|avi|wmv)$") {
    ## images
    set beresp.ttl = 24h;
  }
  else {
    ## fallback / default TTL
    set beresp.ttl = 12m;
  }

  set beresp.http.cache-control = "public,max-age=" + beresp.ttl;
  set beresp.http.X-Cacheable   = "YES:Cache-Control=" + beresp.http.cache-control;
  return (deliver);
}
