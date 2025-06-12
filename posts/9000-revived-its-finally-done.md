Name: its-finally-done
Title: It's Finally done
Description: Revived post from my older blog
Draft: false
Publish Date: Oct 10, 2013
---

I’ve finally finished this website. I thought I’d to a walkthrough for future
reference.

## The Tools

I’m currently self-hosting this website through the following stack:

- [BeagleBone Black](http://beagleboard.org/BLACK)
- [Arch ARM](https://archlinuxarm.org/)
- [Nginx](https://docs.nginx.com/)

I actually bought the BeagleBone Black for self-hosting. It’s something I’ve
always wanted to experiment with and I had to jump on it with its low cost. I
chose Arch ARM because I’m already a fan of Arch Linux. Installation was
extremely short and honestly, it’s probably more user-friendly with it’s own
cherry-picked AUR repo. Nginx is just awesome.

The actual website is built using:

- [Jekyll](https://jekyllrb.com/)
- [Hightlight.js](https://highlightjs.org/)
- [Font Awesome](https://fontawesome.io/)

Jekyll seemed like a wise choice because its by Github and Github is awesome. I
also didn’t know of any other easy to setup blogging platform other than
Wordpress. I know Jekyll does have a built in code syntax highlighting (of
sorts), but it requires Python and I didn’t want another dependency so I went
with highlight.js.

``` console.log("Hello World"); // an example ```

I came across Font Awesome for social media icons and it’s defintely an
overkill, but maybe I can find more uses for it other than the three icons I
have on the top right.

## The Design

Half the time contructing this website was spent trying to figure out how to
make it less…bland. The best method I found was to just look for other blogs
that already looked pretty and copy their ideas. So I added in a big black bar
hoping to achieve the parallax effect like Github’s
[404](https://github.com/404) page, but more subtle. I found the jQuery
[plugin](https://github.com/cameronmcefee/plax) that they use and tried
inplementing it, only to fail miserably. I decided that I should try to
understand what it is actually doing later instead of just doing a copy pasta
from the example. To replace it, I cropped an image from a random wallpaper and
stuck it in. I faded it away in shadow to fit my greyscale-ish theme and made it
focus on hover…becuase it was boring.

Definitely expect design overhauls in the future.

## Now What?

This blog will be moved over to Github Pages and the domain as well. It’s
actually already being mirrored
[here](https://web.archive.org/web/20161004203141/http://hspak.github.io/). I’m
just keeping it on my BeagleBone so I can get used to setting up Nginx and other
server configurations for my next project. I haven’t quite decided what kind of
content I would like to keep here.

Being a static blog site, there’s not much use for javascript. One of my
intentions for this website was to teach myself some javascript on the way, but
there wasn’t anything useful I could think of that would be easy to implement.
So as my next project, I’m thinking about a web app in
[Node.js](https://www.nodejs.org) as my next project, hopefully successfully
hosted on my BeagleBone. It will most likely be a simple chat platform since
that’s what Ryan Dahl seemed to usually do in his talks so I think it’s a good
place to start.
