(1) Fetches your 15 liked videos with titles + thumbnails
(2) Calls videos.list (cheap) to attach categoryId + tags to each liked video
(3) Picks 3 seed videos from distinct categories (running YTApi search.list() on each is 100 units! so (3))
(4) For each seed, builds a title + tags query and calls search.list(maxResults: 50)
(5) Results are deduped + scored via the graph (videos appearing across multiple seeds get a higher score)
(6) Displays ranked neighbors with score in the Recommended tab