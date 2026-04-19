{{c1::YouTubeApi}} represents {{c2::operations/endpoints}} you can call, not a single YouTube resource like one video or one channel.
YouTubeApi provides grouped resources such as {{c1::channels, videos, playlistItems, search}}, each with methods like {{c2::list()}}.
YouTubeApi.youtubeReadonlyScope is an OAuth scope constant for {{c1::read-only YouTube access}}, meaning you can fetch data but not {{c2::modify it}}.
API responses returned from YouTubeApi calls are {{c1::typed Dart response objects}} (e.g., list response classes), not raw {{c2::unstructured JSON-only maps}}.
YouTubeApi is typically used after {{c1::OAuth sign-in/consent}} and before calling endpoint methods like {{c2::channels.list(...) or videos.list(...)}}.