Name: the-github-migration
Title: The GitHub Migration
Description: Revived post from my older blog
Draft: false
Publish Date: Oct 27, 2013
Updated Date: Jul 12, 2014
---

For the sake of moving on and ease of pushing changes, I’ve moved my domain over
to Github Pages and shut nginx down on my BeagleBone. Because I had already
setup pages, there wasn’t much to be done.

Steps
- Create a file titled CNAME in the root directory and write the domain name
inside.
- Push file to masters branch of your Github repo. 
- ~Change your DNS settings for your domain to point to 204.232.175.78. And thats it!~

**Update (July 12, 2014)**: A while back, I got this email from GitHub:

> GitHub Pages recently underwent some improvements
> (https://github.com/blog/1715-faster-more-awesome-github-pages to make your site
> faster and more awesome, but we’ve noticed that www.hspak.com isn’t properly
> configured to take advantage of these new features. While your site will
> continue to work just fine, updating your domain’s configuration offers some
> additional speed and performance benefits. Instructions on updating your site’s
> IP address can be found at
> https://help.github.com/articles/setting-up-a-custom-domain-with-github-pages#step-2-configure-dns-records,
> and of course, you can always get in touch with a human at support@github.com.
> For the more technical minded folks who want to skip the help docs: your site’s
> DNS records are pointed to a deprecated IP address.

The gist of it is, there are two ways to setup your DNS. If you would like
GitHub to point to an apex or naked domain, then you point your a records to
192.30.252.153 or 192.30.252.154. If you would like GitHub to point to a
subdomain, i.e www, create a CNAME to point to username.github.io in your DNS.
GitHub will automatically take care of redirecting from www to apex or
vice-versa.
