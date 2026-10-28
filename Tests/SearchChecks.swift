import Foundation

@MainActor private final class SearchFixture: MediaSearchSource {
    var feedIdentity = "fixture-A"
    var authorQuery: (String) async throws -> [Creator] = { _ in [] }
    var tagQuery: (String,Int) async throws -> [SearchTag] = { _,_ in [] }
    var posts: (String,FeedFilter,PublicationCursor?) async throws -> SearchPostPage = { _,_,_ in .init(items: [],nextCursor: nil) }
    var media: (Int,FeedFilter,String?,Bool) async throws -> MediaPage = { _,_,_,_ in .init(items: [],metadata: .init(nextCursor: nil)) }
    var requests: [(post: Int,cursor: String?,filter: FeedFilter,tags: Bool)] = []
    var postReads = 0
    func searchAuthors(keyword: String) async throws -> [Creator] { try await authorQuery(keyword) }
    func searchTags(keyword: String, page: Int) async throws -> [SearchTag] { try await tagQuery(keyword,page) }
    func searchTitlePosts(keyword: String, filter: FeedFilter, cursor: PublicationCursor?) async throws -> SearchPostPage { postReads += 1; return try await posts(keyword,filter,cursor) }
    func searchPostMedia(postID: Int, filter: FeedFilter, cursor: String?, includeTags: Bool) async throws -> MediaPage {
        requests.append((postID,cursor,filter,includeTags)); return try await media(postID,filter,cursor,includeTags)
    }
}
@MainActor private final class SearchGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void,Never>] = []
    func wait() async { if !opened { await withCheckedContinuation { waiters.append($0) } } }
    func open() { opened = true; let values = waiters; waiters = []; values.forEach { $0.resume() } }
}

@main struct SearchChecks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ reason: String) { precondition(value,reason); count += 1 }
        func rejected(_ action: () async throws -> Void) async -> Bool { do { try await action(); return false } catch { return true } }
        check(!MediaSearchText.valid(" \n",mode: .title) && !MediaSearchText.valid(String(repeating:"a",count:81),mode:.tag),"Empty/overlong input never becomes a generic feed")
        check(!MediaSearchText.valid("a%",mode:.title) && !MediaSearchText.valid("a_b",mode:.tag),"Unsupported SQL wildcards are refused")
        check(MediaSearchText.valid("author_name",mode:.author) && MediaSearchText.normalized(" City ")=="City","Author names retain underscores and keywords trim only edge space")
        check(MediaSearchText.matchesPrefix("City Lights",keyword:"city") && !MediaSearchText.matchesPrefix("The City",keyword:"city") && !MediaSearchText.matchesPrefix(nil,keyword:"city"),"Title matching means prefix, not arbitrary contains or missing text")
        let source=SearchFixture(),lookup=SearchLookupStore()
        func key(_ mode:MediaSearchMode,_ text:String,blocked:Set<String>=[]) -> SearchLookupStore.Key { .init(mode:mode,text:text,identity:source.feedIdentity,blockedTags:blocked) }
        source.authorQuery={_ in (1...25).map{Creator(id:$0,username:"fixture-\($0)",image:nil)}}
        await lookup.reload(key:key(.author,"fixture"),source:source)
        check(lookup.authors.count==20 && lookup.reachedEnd,"Bounded author candidates do not pretend to support unavailable offset paging")
        lookup.clear();check(lookup.authors.isEmpty && lookup.tags.isEmpty && lookup.key==nil && lookup.error==nil,"Clear removes results and request identity")
        source.tagQuery={_,page in (page==1 ? Array(1...20) : Array(20...25)).map{SearchTag(id:$0,name:"city\($0)")}}
        await lookup.reload(key:key(.tag,"city",blocked:["city2"]),source:source)
        check(lookup.tags.count==19 && !lookup.tags.contains(where:{$0.id==2}) && !lookup.reachedEnd,"Blocked tag suggestions hide without falsely ending pagination")
        await lookup.next(source:source)
        check(lookup.tags.count==24 && Set(lookup.tags.map(\.id)).count==24 && lookup.reachedEnd,"Tag-page overlap dedupes and short final page ends")
        source.tagQuery={_,_ in (1...20).map{SearchTag(id:$0,name:"city\($0)")}}
        await lookup.reload(key:key(.tag,"city"),source:source);await lookup.next(source:source)
        check(lookup.error != nil && lookup.tags.count==20,"Repeated tag page is an explicit error")
        var fail=true
        source.tagQuery={_,_ in if fail {throw URLError(.timedOut)};return [.init(id:30,name:"city30")]}
        await lookup.reload(key:key(.tag,"city"),source:source)
        check(lookup.error != nil && !lookup.reachedEnd,"Request failure is distinct from empty results")
        fail=false;await lookup.next(source:source)
        check(lookup.error==nil && lookup.tags.map(\.id)==[30],"Retry retains query and page")
        let start=SearchGate(),release=SearchGate()
        source.authorQuery={keyword in if keyword=="old" {start.open();await release.wait();return [.init(id:1,username:"old",image:nil)]};return [.init(id:2,username:"new",image:nil)]}
        let old=Task{await lookup.reload(key:key(.author,"old"),source:source)}
        await start.wait();await lookup.reload(key:key(.author,"new"),source:source);release.open();await old.value
        check(lookup.authors.map(\.id)==[2],"Late old lookup cannot replace new keywords")
        source.tagQuery={_,_ in [.init(id:1,name:"unrelated")]}
        await lookup.reload(key:key(.tag,"city"),source:source)
        check(lookup.error != nil && lookup.tags.isEmpty,"Ignored tag search cannot display generic suggestions")

        func cursor(_ raw:String) throws -> PublicationCursor {try JSONDecoder().decode(PublicationCursor.self,from:Data(raw.utf8))}
        let p2=try cursor("\"post:2\""),p3=try cursor("3")
        let filter=FeedFilter(kind:.video,sort:"Newest",period:"AllTime",onlyPG:true)
        func item(_ id:Int,post:Int) -> MediaItem {.init(id:id,url:"https://example.com/fixture\(id).mp4",width:nil,height:nil,type:"video",username:"fixture",browsingLevel:1,thumbnail:nil,tags:[.init(id:1,name:"city")],postID:post)}
        source.posts={keyword,f,c in
            precondition(keyword=="City" && f==filter)
            if c==nil {return .init(items:[.init(id:10,title:"City lights"),.init(id:11,title:"City sunset")],nextCursor:p2)}
            if c==p2 {return .init(items:[],nextCursor:p3)}
            return .init(items:[.init(id:12,title:"City rain")],nextCursor:nil)
        }
        source.media={post,_,c,_ in
            if post==10 {return .init(items:(c==nil ? Array(101...108):Array(109...112)).map{item($0,post:post)},metadata:.init(nextCursor:c==nil ? "media:2":nil))}
            return .init(items:[item(post==11 ? 201:301,post:post)],metadata:.init(nextCursor:nil))
        }
        var state:String?,all:[Int]=[],pages=0,emptyContinuation=false
        repeat {
            let page=try await TitleMediaPager.page(keyword:" City ",filter:filter,cursor:state,includeTags:true,source:source)
            all += page.items.map(\.id);emptyContinuation = emptyContinuation || (page.items.isEmpty && page.metadata.nextCursor != nil)
            state=page.metadata.nextCursor;pages += 1;precondition(pages<=8)
        } while state != nil
        check(all==Array(101...112)+[201,301],"Title search expands all post media, including beyond preview cover cap")
        check(source.requests.map(\.post)==[10,10,11,12] && source.requests[1].cursor=="media:2","Each post media cursor finishes before advancing to next matched post")
        check(emptyContinuation && source.postReads==3,"Permission-filtered empty post page keeps opaque continuation")
        check(source.requests.allSatisfy({$0.filter==filter && $0.tags}),"Media type, range, content filter and actual tag reads propagate through title expansion")
        let encoded=try JSONEncoder().encode(p2)
        check(try JSONDecoder().decode(PublicationCursor.self,from:encoded)==p2,"String/number site cursors retain type when wrapped locally")
        source.posts={_,_,_ in .init(items:[.init(id:10,title:"City test")],nextCursor:p2)}
        source.media={post,_,_,_ in .init(items:[item(1,post:post)],metadata:.init(nextCursor:nil))}
        let first=try await TitleMediaPager.page(keyword:"City",filter:filter,cursor:nil,includeTags:true,source:source)
        check(await rejected{_ = try await TitleMediaPager.page(keyword:"Other",filter:filter,cursor:first.metadata.nextCursor,includeTags:true,source:source)},"Wrapped cursor cannot be reused for another keyword")
        check(await rejected{_ = try await TitleMediaPager.page(keyword:"City",filter:FeedFilter(kind:.image),cursor:first.metadata.nextCursor,includeTags:true,source:source)},"Wrapped cursor cannot cross media filters")
        check(await rejected{_ = try await TitleMediaPager.page(keyword:"City",filter:filter,cursor:first.metadata.nextCursor,includeTags:true,source:source)},"Repeated post cursor is rejected before more generic results")
        source.posts={_,_,_ in .init(items:[.init(id:10,title:"Unrelated")],nextCursor:nil)}
        let mediaReads=source.requests.count
        check(await rejected{_ = try await TitleMediaPager.page(keyword:"City",filter:filter,cursor:nil,includeTags:true,source:source)} && source.requests.count==mediaReads,"Unmatched titles are errors rather than false search results")
        source.posts={_,_,_ in .init(items:[.init(id:10,title:"City")],nextCursor:nil)}
        source.media={_,_,_,_ in .init(items:[item(1,post:99)],metadata:.init(nextCursor:nil))}
        check(await rejected{_ = try await TitleMediaPager.page(keyword:"City",filter:filter,cursor:nil,includeTags:true,source:source)},"Wrong-post hydration cannot escape search scope")
        source.media={post,_,_,_ in .init(items:[item(1,post:post)],metadata:.init(nextCursor:"repeat"))}
        let repeatPage=try await TitleMediaPager.page(keyword:"City",filter:filter,cursor:nil,includeTags:true,source:source)
        check(await rejected{_ = try await TitleMediaPager.page(keyword:"City",filter:filter,cursor:repeatPage.metadata.nextCursor,includeTags:true,source:source)},"Repeated within-post media cursor is bounded")
        source.posts={_,_,_ in source.feedIdentity="changed";return .init(items:[.init(id:10,title:"City")],nextCursor:nil)}
        check(await rejected{_ = try await TitleMediaPager.page(keyword:"City",filter:filter,cursor:nil,includeTags:true,source:source)},"Account changes reject late post responses")
        source.feedIdentity="fixture-A";source.posts={_,_,_ in .init(items:[],nextCursor:nil)}
        let empty=try await TitleMediaPager.page(keyword:"City",filter:filter,cursor:nil,includeTags:true,source:source)
        check(empty.items.isEmpty && empty.metadata.nextCursor==nil,"Genuine complete empty search ends")
        let reads=source.postReads
        check(await rejected{_ = try await TitleMediaPager.page(keyword:" ",filter:filter,cursor:nil,includeTags:true,source:source)} && source.postReads==reads,"Empty title never makes an unscoped global request")
        check(await rejected{_ = try await TitleMediaPager.page(keyword:"City",filter:filter,cursor:"invalid",includeTags:true,source:source)},"Malformed opaque state cannot restart at page one")

        let suite="CivitViewer.SearchChecks."+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
        defer{defaults.removePersistentDomain(forName:suite)}
        let blocks=TagBlocklist(defaults:defaults)
        blocks.add("city")
        check(blocks.names==["city"] && TagBlocklist(defaults:defaults).names==["city"],"Detail tag choice persists immediately for new search contexts")
        blocks.remove("city")
        check(blocks.names.isEmpty && TagBlocklist(defaults:defaults).names.isEmpty,"Undo before closing persists")
        blocks.add("city");blocks.add("city")
        check(blocks.names==["city"],"Repeated tag actions are idempotent")
        var feed=FeedAccumulator()
        feed.append(.init(items:[item(1,post:10)],metadata:.init(nextCursor:"keep-position")))
        feed.applyBlockedTags(["city"])
        check(feed.items.isEmpty && feed.cursor=="keep-position" && !feed.reachedEnd && feed.blockedCount==1,"Tag visibility changes retain raw loaded records and cursor")
        feed.applyBlockedTags([])
        check(feed.items.map(\.id)==[1] && feed.cursor=="keep-position","Removing block restores loaded work without network reset to top")

        check(BiographyText.plain("Hello\n世界")=="Hello\n世界","Plain original biography retains meaning and line breaks")
        check(BiographyText.plain("<p>A &amp; B</p><script>alert(1)</script><img src='https://example.com/x'><p>C</p>")=="A & B\nC","HTML becomes native plain text without scripts, images or remote requests")
        check(BiographyText.plain("<a href='javascript:alert(1)'>hello</a>")=="hello","Unsafe rich-text href cannot become a clickable link")
        check(BiographyText.plain("<a href='https://example.com/a'>Website</a>").contains("https://example.com/a"),"Safe author website target is retained")
        check(BiographyText.decodeEntities("&#x4E2D;&#25991; &lt;ok&gt;")=="中文 <ok>","Numeric and named entities decode as text")
        check(["javascript:alert(1)","file:///etc/passwd","data:text/html,abc","https://u:p@example.com"].allSatisfy{BiographyText.safeURL($0)==nil},"Only ordinary web links without embedded credentials are offered")
        check(BiographyText.links(in:"https://example.com/a https://example.com/a").count==1,"External links deduplicate without evaluating markup")
        let profile=try JSONDecoder().decode(CreatorBiography.self,from:Data(#"{"id":7,"username":"fixture","profile":{"bio":null}}"#.utf8))
        check(profile.profile?.bio==nil && BiographyText.plain(profile.profile?.bio ?? "").isEmpty,"Empty bio stays an explicit empty state")
        let selectedAuthor=Creator(id:7,username:"fixture",image:nil)
        let a=SearchTag(id:1,name:"city"),b=SearchTag(id:2,name:"night"),c=SearchTag(id:3,name:"rain")
        let criteria=MediaSearchCriteria(text:" City ",author:selectedAuthor,tags:[a,b])
        check(criteria.valid && !MediaSearchCriteria().valid,"Multiple independent conditions require at least one actual scope")
        check(MediaSearchCriteria(author:selectedAuthor).valid && MediaSearchCriteria(tags:[a]).valid && MediaSearchCriteria(text:"City").valid,"Author, tag and title remain independently optional")
        check(criteria.id==MediaSearchCriteria(text:"city",author:selectedAuthor,tags:[b,a]).id,"Condition identity normalizes title case and tag order")
        check(criteria.id != MediaSearchCriteria(text:"city",author:selectedAuthor,tags:[a,c]).id,"Changed tag condition has a different result/cursor identity")
        check(!MediaSearchCriteria(tags:Array(repeating:a,count:9)).valid && !MediaSearchCriteria(tags:[.init(id:0,name:"bad")]).valid,"Bound tag count and reject unresolved tag IDs")
        var both=item(1,post:11);both.tags=[.init(id:1,name:"city"),.init(id:2,name:"night")]
        check(try criteria.matches(both),"Text-scoped post media must satisfy selected author and every tag")
        var witnessed = both; witnessed.tags?.append(.init(id:nil,name:"unrelated"))
        check(try criteria.matches(witnessed),"Known required IDs remain valid when an unrelated label has no ID")
        check(try MediaSearchCriteria(tags:[a]).matches(witnessed),"Single-tag search uses the same witnessed ID rule")
        var incomplete = both; incomplete.tags=[.init(id:1,name:"city"),.init(id:nil,name:"unrelated")]
        check(await rejected{_ = try criteria.matches(incomplete)},"A missing required ID with unknown labels stays unverified")
        check(try !criteria.matches(item(2,post:11)),"One matching tag is insufficient for AND conditions")
        let other=MediaItem(id:3,url:"https://example.com/fixture.mp4",width:nil,height:nil,type:"video",username:"other",browsingLevel:1,thumbnail:nil,tags:[.init(id:1,name:"city"),.init(id:2,name:"night")],postID:11)
        check(try !criteria.matches(other),"Author and tags combine with AND, not OR")
        var unknown=both;unknown.tags=nil
        check(await rejected{_ = try criteria.matches(unknown)},"Unknown tag metadata is not treated as a match")
        source.feedIdentity="fixture-A"
        source.posts={_,_,_ in .init(items:[.init(id:10,title:"City wrong author",user:.init(id:8)),.init(id:11,title:"City right author",user:.init(id:7))],nextCursor:p2)}
        source.media={_,_,_,_ in .init(items:[both],metadata:.init(nextCursor:nil))}
        let combined=try await TitleMediaPager.page(keyword:"City",filter:filter,cursor:nil,includeTags:true,source:source,criteria:criteria)
        check(combined.items.map(\.id)==[1] && source.requests.last?.post==11,"Combined author/title scope expands only matching-author posts, including the owner's own account without ignored-title fallback")
        check(await rejected{_ = try await TitleMediaPager.page(keyword:"City",filter:filter,cursor:combined.metadata.nextCursor,includeTags:true,source:source,criteria:MediaSearchCriteria(text:"City",author:selectedAuthor,tags:[c]))},"Combined cursor cannot cross selected tags")
        source.posts={_,_,_ in .init(items:[.init(id:10,title:"City other",user:.init(id:8))],nextCursor:p2)}
        let hidden=try await TitleMediaPager.page(keyword:"City",filter:filter,cursor:nil,includeTags:true,source:source,criteria:criteria)
        check(hidden.items.isEmpty && hidden.metadata.nextCursor != nil,"An all-filtered post batch retains continuation for combined conditions")
        source.posts={_,_,_ in .init(items:[.init(id:10,title:"City unknown owner")],nextCursor:nil)}
        check(await rejected{_ = try await TitleMediaPager.page(keyword:"City",filter:filter,cursor:nil,includeTags:true,source:source,criteria:criteria)},"Missing post owner metadata remains unverified")
        let directorySource=DirectoryFixture(),directory=TagDirectoryStore()
        directorySource.common=[a,b]
        await directory.reload(key:.init(mode:.common,keyword:"",identity:directorySource.feedIdentity),source:directorySource)
        check(directory.tags==[a,b] && directory.reachedEnd,"Common tags use the server list without inventing a popularity count")
        directorySource.catalog={_,page in (page==1 ? Array(1...20) : Array(20...24)).map{SearchTag(id:$0,name:"tag\($0)")}}
        await directory.reload(key:.init(mode:.catalog,keyword:"",identity:directorySource.feedIdentity),source:directorySource)
        check(directory.tags.count==20 && !directory.reachedEnd,"A full catalog batch offers continuation without a fabricated total")
        await directory.next(source:directorySource)
        check(directory.tags.count==24 && directory.reachedEnd,"Directory page overlaps dedupe and a short final page ends")
        directorySource.catalog={_,_ in (1...20).map{SearchTag(id:$0,name:"tag\($0)")}}
        await directory.reload(key:.init(mode:.catalog,keyword:"",identity:directorySource.feedIdentity),source:directorySource);await directory.next(source:directorySource)
        check(directory.error != nil && directory.tags.count==20,"Repeated catalog pages cannot append duplicates indefinitely")
        directorySource.catalog={_,_ in throw URLError(.timedOut)}
        await directory.reload(key:.init(mode:.catalog,keyword:"tag",identity:directorySource.feedIdentity),source:directorySource)
        check(directory.error != nil && !directory.reachedEnd,"Directory errors are not empty success")
        directorySource.catalog={_,_ in [.init(id:30,name:"tag30")]};await directory.next(source:directorySource)
        check(directory.error==nil && directory.tags.map(\.id)==[30],"Directory retry keeps its page/query scope")
        let directoryStarted=SearchGate(),directoryRelease=SearchGate()
        directorySource.catalog={query,_ in if query=="old" {directoryStarted.open();await directoryRelease.wait();return [.init(id:1,name:"old")]};return [.init(id:2,name:"new")]}
        let oldDirectory=Task{await directory.reload(key:.init(mode:.catalog,keyword:"old",identity:directorySource.feedIdentity),source:directorySource)}
        await directoryStarted.wait();await directory.reload(key:.init(mode:.catalog,keyword:"new",identity:directorySource.feedIdentity),source:directorySource);directoryRelease.open();await oldDirectory.value
        check(directory.tags.map(\.id)==[2],"Late directory query cannot replace a newer search")
        let canceledLaunch=SearchGate()
        let canceledReload=Task {await canceledLaunch.wait();await directory.reload(key:.init(mode:.common,keyword:"",identity:directorySource.feedIdentity),source:directorySource)}
        canceledReload.cancel();canceledLaunch.open();await canceledReload.value
        check(directory.tags.map(\.id)==[2] && directory.key?.keyword=="new","A canceled view task cannot clear an already loaded directory or claim a new request key")
        let cancellationStarted=SearchGate(),cancellationRelease=SearchGate()
        directorySource.catalog={_,_ in cancellationStarted.open();await cancellationRelease.wait();return [.init(id:30,name:"cat")]}
        let activeDirectory=Task {await directory.reload(key:.init(mode:.catalog,keyword:"c",identity:directorySource.feedIdentity),source:directorySource)}
        await cancellationStarted.wait();activeDirectory.cancel();cancellationRelease.open();await activeDirectory.value
        check(directory.error != nil && directory.tags.isEmpty && !directory.reachedEnd && !directory.loading,"A canceled active directory read is retryable, never empty-success")
        directorySource.catalog={_,_ in [.init(id:31,name:"cat")]};await directory.next(source:directorySource)
        check(directory.tags.map(\.id)==[31] && directory.error==nil,"A canceled directory can retry the same page and scope")
        let namedVocabulary = TagCatalogQuery.input(keyword: " Gaping ", page: 2)
        check(namedVocabulary["query"] as? String == "gaping" && namedVocabulary["page"] as? Int == 2,"Tag lookup preserves normalized user keyword and page")
        check(["entityType","types","nsfwLevel","moderation","withModels","categories"].allSatisfy { namedVocabulary[$0] == nil },"Named vocabulary never restricts tag targets, classes or media grades")
        let publicVocabulary = TagCatalogQuery.input(keyword: "", page: 1)
        check(publicVocabulary["query"] == nil && publicVocabulary["entityType"] == nil && publicVocabulary["nsfwLevel"] == nil && publicVocabulary["limit"] as? Int == 20,"Empty directory requests all public types and lets the server decide its default visibility")
        check(["!!","!?","+ +","+++","0 0","1980"].allSatisfy{!TagDirectoryQuality.includes($0)},"Punctuation and numeric placeholders are hidden from the directory")
        check(["1920's","1980s","1930s (style)","90s aesthetic","19th century","1990年代","20世纪"].allSatisfy{!TagDirectoryQuality.includes($0)},"Requested decade and century labels are hidden")
        check(["3d","18-wheeler truck","cat","猫","1980s car"].allSatisfy{TagDirectoryQuality.includes($0)},"Meaningful numeric names and international subject labels remain available")
        var noisePages:[Int]=[]
        directorySource.catalog={_,page in noisePages.append(page);return page<4 ? (1...20).map{.init(id:page*100+$0,name:"!!")} : [.init(id:999,name:"portrait")]}
        await directory.reload(key:.init(mode:.catalog,keyword:"",identity:directorySource.feedIdentity),source:directorySource)
        check(directory.tags.isEmpty && directory.hiddenNoiseCount==60 && !directory.reachedEnd && noisePages==[1,2,3],"Noise filtering is bounded to three raw pages and preserves continuation instead of false completion")
        await directory.next(source:directorySource)
        check(directory.tags.map(\.id)==[999] && directory.reachedEnd && noisePages==[1,2,3,4],"A fully filtered batch can continue to meaningful tags on the next raw page")
        print("SearchChecks: \(count) search, detail-policy and biography checks passed")
    }
}

@MainActor private final class DirectoryFixture: TagDirectorySource {
    var feedIdentity="directory-A"
    var common:[SearchTag]=[]
    var catalog:(String,Int) async throws -> [SearchTag]={_,_ in []}
    func commonTags() async throws -> [SearchTag] {common}
    func catalogTags(keyword:String,page:Int) async throws -> [SearchTag] {try await catalog(keyword,page)}
    func exactTag(name:String) async throws -> SearchTag? {common.first{$0.name==name}}
}
