# Site-level storyboard overrides for this deployment.
# Included after common.story — functions here override common.story definitions.

# Disable AV scanning (no AV plugin configured).
function(checknoscanlists)
function(checknoscantypes)

# Override bannedcheck to also check bannedsitelist (sitein) for HTTP requests.
# common.story's bannedcheck only calls urlin (URL list), missing site-level bans.
function(bannedcheck)
if(true) returnif checkblanketblock
if(sitein, banned) return setblock
if(urlin, banned) return setblock
ifnot(urlin,exceptionfile) returnif checkurlextension
if(useragentin, banneduseragent) return setblock
if(headerin, bannedheader) return setblock
