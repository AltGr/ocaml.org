(** Render an RSS feed to HTML, for the headlines or the actual posts. *)

open Printf
open Nethtml

(** List of "authors" that send text descriptions (as opposed to
    HTML).  The formatting of the description must then be respected. *)
let text_description = []

let channel_of_urls urls =
  let download_and_parse url =
    let ch, err = Rss.channel_of_string(Http.get url) in
    List.iter (fun e -> printf "RSS error (URL=%s): %s\n" url e) err;
    ch in
  let channels = List.map download_and_parse urls in
  match channels with
  | [] -> invalid_arg "rss2html.channel_of_urls: empty URL list"
  | [c] -> c
  | c :: tl -> List.fold_left Rss.merge_channels c tl


(* Our representation of a "post". *)
type post = {
  title  : string;
  link   : Rss.url option;   (* url of the original post *)
  date   : Rss.date option;
  author : string;
  email  : string;    (* the author email, "" if none *)
  desc   : string;
}

let digest_post p = match p.link with
  | None -> Digest.to_hex (Digest.string (p.title))
  | Some u -> Digest.to_hex (Digest.string (p.title ^ Neturl.string_of_url u))

let string_of_option = function None -> "" | Some s -> s

let re_colon = Str.regexp " *: *"

(* Transform an RSS item into a [post]. *)
let parse_item it =
  let open Rss in
  let title = string_of_option it.item_title in
  let author, title =
    (* The author name is often put before the title, separated by ':'. *)
    match Str.bounded_split re_colon title 2 with
    | [_] -> "", title
    | [author; title] -> author, title
    | _ -> assert false in
  let link = match it.item_guid, it.item_link with
    | Some(Guid_permalink u), _ -> Some u
    | _, Some _ -> it.item_link
    | Some(Guid_name u), _ ->
       (* Sometimes the guid is indicated with isPermaLink="false" but
          is nonetheless the only URL we get (e.g. ocamlpro). *)
       (try Some(Neturl.parse_url u) with _ -> it.item_link)
    | None, None -> None in
  { title; link; author;
    email = string_of_option it.item_author;
    desc = string_of_option it.item_desc;
    date = it.item_pubdate }


(* Limit the length of the description presented to the reader. *)

let rec length_html html =
  List.fold_left (fun l h -> l + length_html_el h) 0 html
and length_html_el = function
  | Element(_, _, content) -> length_html content
  | Data d -> String.length d

let rec text_of_html html =
  String.concat "" (List.map text_of_el html)
and text_of_el = function
  | Element(_, _, content) -> text_of_html content
  | Data d -> d

let rec prefix_of_html html len = match html with
  | [] -> []
  | el :: tl ->
     let l = length_html_el el in
     if l < len then el :: prefix_of_html tl (len - l)
     else [] (* FIXME: naive, descend into el *)


let new_id =
  let id = ref 0 in
  fun () -> incr id; sprintf "post%i" !id

(* [toggle html1 html2] return some piece of html with buttons to pass
   from [html1] to [html2] and vice versa. *)
let toggle ?(anchor="") html1 html2 =
  let button id1 id2 text =
    Element("a", ["onclick", sprintf "switchContent('%s','%s')" id1 id2;
                  "class", "btn planet-toggle";
                  "href", "#" ^ anchor],
            [Data text])
  in
  let id1 = new_id() and id2 = new_id() in
  [Element("div", ["id", id1],
           html1 @ [button id1 id2 "Read more..."]);
   Element("div", ["id", id2; "style", "display: none"],
           html2 @ [button id2 id1 "Hide"])]

let toggle_script =
  let script =
    "function switchContent(id1,id2) {
     // Get the DOM reference
     var contentId1 = document.getElementById(id1);
     var contentId2 = document.getElementById(id2);
     // Toggle
     contentId1.style.display = \"none\";
     contentId2.style.display = \"block\";
     }\n" in
  [Element("script", ["type", "text/javascript"], [Data script])]


(* Transform a post [p] (i.e. story) into HTML. *)
let html_of_post p =
  let title_anchor = digest_post p in
  let html_title, rss = match p.link with
    | None -> [Data p.title], []
    | Some u ->
       let url = Neturl.string_of_url u in
       [Element("a", ["href", url; "target", "_blank";
                      "title", "Go to the original post"],
                [Data p.title]) ],
       [Element("a", ["href", url; "alt", "RSS"; "target", "_blank";
                      "class", "rss"],
                [Element("img", ["src", "/img/rss.png"], []) ]) ] in
  let html_author =
    if p.email = "" then Data p.author
    else Element("a", ["href", "mailto:" ^ p.email], [Data p.author]) in
  let sep = Data " — " in
  let additional_info = match p.date with
    | None ->
       if p.author = "" then [] else [sep; html_author]
    | Some d ->
       if p.author = "" then [sep; Data(Netdate.format ~fmt:"%B %e, %Y" d)]
       else [sep; html_author; Data ", ";
             Data(Netdate.format ~fmt:"%b %e, %Y" d)] in
  let additional_info =
    [Element("span", ["style", "font-size: 65%; font-weight:normal"],
             additional_info)] in
  let desc =
    if List.mem p.author text_description then
      [Element("pre", ["class", "rss-text"], [Data p.desc])]
    else
      let desc = Nethtml.parse (new Netchannels.input_string p.desc) in
      if length_html desc < 1200 then desc
      else toggle (prefix_of_html desc 1200) desc ~anchor:title_anchor
  in
  [Data "\n";
   Element("a", ["name", title_anchor], []);
   Element("section", ["class", " condensed"; "style", "clear: both"],
           Element("h1", ["class", "ruled planet"],
                   rss @ html_title @ additional_info)
           :: desc);
   Data "\n"]

(* Similar to [html_of_post] but tailored to be shown in a list of
   news (only titles are shown, linked to the page with the full story). *)
let headline_of_post ?link ~img p =
  let link = match link with
    | None -> "/community/planet.html#" ^ digest_post p
    | Some l -> l in
  let html_icon =
    [Element("a", ["href", link],
             [Element("img", ["src", img], [])])] in
  let html_date = match p.date with
    | None -> html_icon
    | Some d -> let d = Netdate.format ~fmt:"%B %e, %Y" d in
               Element("p", [], [Data d]) :: html_icon in
  let html_title =
    Element("h1", [], [Element("a", ["href", link], [Data p.title])]) in
  [Element("li", [], [Element("article", [], html_title :: html_date)]);
   Data "\n"]

let rec take n = function
  | [] -> []
  | e :: tl -> if n > 0 then e :: take (n-1) tl else []

let posts_of_urls ?n urls =
  let ch = channel_of_urls urls in
  let items = Rss.sort_items_by_date ch.Rss.ch_items in
  let posts = List.map parse_item items in
  match n with
  | None -> posts
  | Some n -> take n posts

let headlines ?n ~img urls =
  let posts = posts_of_urls ?n urls in
  [Element("ul", ["class", "news-feed"],
           List.concat(List.map (headline_of_post ~img) posts))]

let posts ?n urls =
  let posts = posts_of_urls ?n urls in
  [Element("div", [], List.concat(List.map html_of_post posts))]

(** [email_threads] does basically the same as [headlines] but does
    not use the provided links in the posts, point to Inria archives
    instead.  It also presents the subject better. *)
let caml_list_re = Str.regexp_case_fold "^\\(Re: *\\)*\\[[a-zA-Z-]+\\] *"

let email_threads ?n ~img urls =
  let posts = posts_of_urls ?n urls in
  let headline_of_email p =
    let title = Str.replace_first caml_list_re "" p.title in
    let p = { p with title } in
    let link =
      match p.date with
      | None -> "https://sympa.inria.fr/sympa/arc/caml-list/"
      | Some d ->
         Netdate.format d
           ~fmt:"https://sympa.inria.fr/sympa/arc/caml-list/%Y-%m/thrd4.html"
    in
    headline_of_post ~link ~img p in
  [Element("ul", ["class", "news-feed"],
           List.concat(List.map headline_of_email posts))]


(* OPML -- subscriber list
 ***********************************************************************)

module OPML = struct
  type contributor = {
    name  : string;
    title : string;
    url   : string;
  }

  (* Use Xmlm for the parsing, mostly because it is already needed by
     the [Rss] module => no additional dep. *)

  let contributors_of_url url =
    let fh = Xmlm.make_input (`String(0, Http.get url))  in
    let contrib = ref [] in
    try
      while true do
        match Xmlm.input fh with
        | `El_start((_, "outline"), args) ->
           contrib := { name = List.assoc ("", "text") args;
                        title = List.assoc ("", "text") args;
                        url = List.assoc ("", "xmlUrl") args;
                      } :: !contrib
        | _ -> ()
      done;
      assert false
    with Xmlm.Error(_, `Unexpected_eoi) ->
      let cs =
        List.sort (fun c1 c2 -> String.compare c1.name c2.name) !contrib
      in
      let contrib_html c =
        Element("li", [], [Element("a", ["href", c.url], [Data c.name])])
      in
      Element("ul", [], List.map contrib_html cs)

  let contributors urls =
    List.map contributors_of_url urls
end


let () =
  let urls = ref [] in
  let action = ref `Posts in
  let n_posts = ref None in (* ≤ 0 means unlimited *)
  let img = ref "/img/news.png" in
  let specs = [
    ("--headlines", Arg.Unit(fun () -> action := `Headlines),
     " RSS feed to feed summary (in HTML)");
    ("--emails", Arg.Unit(fun () -> action := `Emails),
     " RSS feed of email threads to HTML");
    ("--subscribers", Arg.Unit(fun () -> action := `Subscribers),
     " OPML feed to list of subscribers (in HTML)");
    ("--posts", Arg.Unit(fun () -> action := `Posts),
     " RSS feed to HTML (default action)");
    ("-n", Arg.Int(fun n -> n_posts := Some n),
     "n limit the number of posts to n (default: all of them)");
    ("--img", Arg.Set_string img,
     sprintf "url set the images URL for each headline (default: %S)" !img) ] in
  let anon_arg s = urls := s :: !urls in
  Arg.parse (Arg.align specs) anon_arg "rss2html <URLs>";
  if !urls = [] then (
    Arg.usage (Arg.align specs) "rss2html <at least 1 URL>";
    exit 1);
  let out = new Netchannels.output_channel stdout in
  (match !action with
   | `Headlines -> Nethtml.write out (headlines ?n:!n_posts ~img:!img !urls)
   | `Emails -> Nethtml.write out (email_threads ?n:!n_posts ~img:!img !urls)
   | `Posts -> Nethtml.write out (toggle_script @ posts ?n:!n_posts !urls)
   | `Subscribers -> Nethtml.write out (OPML.contributors !urls)
  );
  out#close_out()
