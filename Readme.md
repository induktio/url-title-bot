# URL Title Bot
* announce titles of URLs pasted to an IRC channel
* logs newest urls to a HTML file
* HTML can be uploaded somewhere or just symlinked to public_html
* also saves urls to a database file
* reads some FB and Twitter post metadata
* fuzzy filtering to avoid spamming the obvious titles


### Requirements
* Perl 5.10
* <code>apt-get install libbot-basicbot-perl libio-socket-ssl-perl libconfig-file-perl</code>

### Usage
* rename <code>urlbot_default.conf</code> to <code>urlbot.conf</code> and adjust the settings (required)
* <code>[screen] perl urlbot.pl</code>


