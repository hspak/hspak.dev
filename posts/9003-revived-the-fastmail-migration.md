Name: the-fastmail-migration
Title: The FastMail Migration
Description: Revived post from my older blog
Draft: false
Publish Date: May 26, 2014
---
*(revive notes: lost a lot of images)*

I began my switch from Gmail to FastMail this weekend. I also decided to grab
their enhanced package which allows custom domains with their email service[1].

## Rationale

1. Reduce Google Dependency: It’s becoming increasingly difficult to find an
   internet service that Google hasn’t already taken a strong hold of. This
   isn’t necessarily a bad thing. Better integration between services generally
   equal greater convenience. However the tradeoff of the additional convenience
   is the amount of information they have access of you. I’m not going into tin
   foil hat mode, but I think it’s best kept in moderation. Things like Google
   Drive, Chrome and Android sync are all too useful to completely abandon my
   Google entirely. From now on, Gmail will only be a tool to access other
   Google services.

2. Web Client Performance: The Google web client feels very sluggish. From
   changing folders to opening emails, there’s is a noticeable delay in almost
   every action. The yellow loading bar at the top of the page of Gmail has been
   becoming more and more noticeable over the years. FastMail’s web client is
   much faster than Gmails. The UI is very clean, simple and intutive; there
   wasn’t much to learn except for a few new keyboard shortcuts switching over.

3. Custom Domain: This is something I’ve always wanted to have. Email is still
   central to your online identity and it’s nice to have it be a bit more
   personal.

## DNS Setup

The first thing to do is point the DNS records of your domain to FastMail’s
servers. For Namecheap, there should be a tab labeled Transfer DNS to webhost
when under domain options. I’ve already transferred my DNS settings so it won’t
look exactly like this. It should look similar to the following for other
registrars too:

`missing-image`

FastMail also allows you to point simply their MX server’s instead if you’d like
to keep your current DNS servers.

If you do decided to change DNS records, the current DNS settings are no longer
valid and your websites will not work. The same settings must be re-applied in
FastMail’s servers. If you use an apex domain like I do, make sure you delete
the default A record entry even after you add in your new ones. I didn’t do this
initially, and this blog wouldn’t always resolve correctly. Go under Advanced ->
Custom DNS to see something like this. The first two records are the relevant
ones.

`missing-image`

## Mail Setup Once all the DNS settings have settled, FastMail will email you to
let you know everything is good to go. If you go under Advanced -> Virtual
Domains, you can now setup your custom domain for your email. Scroll down to the
Virtual Domains section and add your domain.

`missing-image`

Then scroll up to the Virtual Aliases section and chose whatever name you’d like
for your email. You are allowed to use a wildcard and have anything sent to
@yourdomain to fill your inbox.

`missing-image`

FastMail has more documented instructions here.

## Transition

I decided against transferring all my old mail over. Chances are, I’m never
going to look at them again and I’m not entirely abandoning my Gmail either.
This also gives me a new chance to reorganize my mail into a more structured
layout where as before, majority of my read emails remained in my inbox. I’ll be
sure to write a review of my experience after another month or two of usage.

----

[1] [FastMail](https://app.fastmail.com/signup/personal.html?domain=fastmail.fm)
