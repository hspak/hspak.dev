Name: quick-and-easy-mutt-setup
Title: Quick and Easy Mutt Setup
Description: Revived post from my older blog
Draft: false
Publish Date: July 13, 2014
---

[Mutt](http://www.mutt.org/) is a powerful text-based email client which I found very nice to use for following open source development (without GitHub). For people with workflow that’s highly dependent on email, like [Greg Kroah-Hartman](https://www.youtube.com/watch?v=IYsdk_N96vA) – a Linux kernel developer/maintainer, I would highly recommend you give mutt a try. You could consider mutt the vim equivalent for email. It is highly customizable which comes at the cost of being incredibly annoying to setup, until now :D.

The obvious pitfall of being text-based is the inability to render HTML emails. This can be partially remedied through mutt’s ability to invoke outside programs for particular mimetypes. It let’s you view inline HTML emails using lynx or w3m, text-based web browsers. With them, the HTML emails are at least readable (unless there were loads of images, then the url spam makes it unbearable…).

## Setup

The first setup is to install mutt and check that it has the builtin imap and stmp features enabled. I can’t speak for any other distros, but here is what Arch has enabled by default:

```
./configure --prefix=/usr --sysconfdir=/etc \
              --enable-gpgme --enable-pop \
              --enable-imap --enable-smtp \ <------ these
              --enable-hcache --with-curses=/usr \
              --with-regex --with-gss=/usr \
              --with-ssl=/usr --with-sasl \
              --with-idn
```

The imap and smtp flags are important for an easy setup. There are external programs that work well with mutt, but they add additional overhead in getting everything setup properly. As an example, offlineimap stores all your email locally and mutt reads those files. Your emails don’t automatically update and getting folder names to sync properly between local and the imap server were a pain to setup.

Common tools used with mutt:

* Offlineimap - for receiving email
* Msmtp - for sending email

The following is a stripped down template of what I use that works for FastMail. Figure out your imap and smtp servers and ports. The template will work out of the box for FastMail. Copy the following into ~/.muttrc and launch mutt. The default hotkey to switch between folders is ‘y’. There you have it, a fully functional mutt.

```
# from setup_settings
set my_server = "mail.messagingengine.com"
set my_smtp_server = "mail.messagingengine.com"
set my_user = "EMAIL"
set my_pass = "PASS"

# imap
set mbox_type       = Maildir         # mailbox type
set imap_user       = $my_user
set imap_pass       = $my_pass
set folder          = "imaps://$my_server"
set spoolfile       = "=INBOX"
set postponed       = "=INBOX.Drafts"

set mailboxes "=INBOX" # add folders here like "=INBOX.label"

# going through fastmail, setting this will save the email twice
unset record

# smtp
set smtp_pass = $my_pass
set smtp_url = smtp://$my_user@$my_smtp_server:587/
set ssl_starttls = yes

set realname = "NAME"
```

The most annoying part to setting everything up is figuring out the folder names for everything. For FastMail, everything is prefixed ‘=’ and folders are period (.) separated[1].

For GMail, I believe everything is prefixed ‘+’ and folders are backslash separated (/) (i.e +Gmail/INBOX +Gmail/Label). Take this with a grain of salt.

The [ArchWiki](/https://wiki.archlinux.org/index.php/Mutt) is a good resource for setting up a lot of things with mutt.

If you’d like to see my setup, the config files are here.

----
[1] [FastMail](https://www.fastmail.help/hc/en-us/articles/1500000278342-Server-names-and-ports?d)
