--
-- Haddock - A Haskell Documentation Tool
--
-- (c) Simon Marlow 2003
--

module HaddockHtml ( 
	ppHtml, copyHtmlBits, 
	ppHtmlIndex, ppHtmlContents,
	ppHtmlHelpFiles
  ) where

import Prelude hiding (div)

import Binary2 ( openBinaryFile )
import HaddockDevHelp
import HaddockHH
import HaddockHH2
import HaddockModuleTree
import HaddockTypes
import HaddockUtil
import HaddockVersion
import Html
import qualified Html
import Map ( Map )
import qualified Map hiding ( Map )

import Control.Exception ( bracket )
import Control.Monad ( when, unless )
import Data.Char ( isUpper, toUpper )
import Data.List ( sortBy )
import Data.Maybe ( fromJust, isJust, mapMaybe, fromMaybe )
import Foreign.Marshal.Alloc ( allocaBytes )
import System.IO ( IOMode(..), hClose, hGetBuf, hPutBuf )

import GHC 
import Name
import Module
import RdrName hiding ( Qual )
import SrcLoc   
import FastString ( unpackFS )
import BasicTypes ( IPName(..), Boxity(..) )
import Kind
--import Outputable ( ppr, defaultUserStyle )

-- the base, module and entity URLs for the source code and wiki links.
type SourceURLs = (Maybe String, Maybe String, Maybe String)
type WikiURLs = (Maybe String, Maybe String, Maybe String)

-- -----------------------------------------------------------------------------
-- Generating HTML documentation

ppHtml	:: String
	-> Maybe String				-- package
	-> [HaddockModule]
	-> FilePath			-- destination directory
	-> Maybe (GHC.HsDoc GHC.RdrName)    -- prologue text, maybe
	-> Maybe String		        -- the Html Help format (--html-help)
	-> SourceURLs			-- the source URL (--source)
	-> WikiURLs			-- the wiki URL (--wiki)
	-> Maybe String			-- the contents URL (--use-contents)
	-> Maybe String			-- the index URL (--use-index)
	-> IO ()

ppHtml doctitle maybe_package hmods odir prologue maybe_html_help_format
	maybe_source_url maybe_wiki_url
	maybe_contents_url maybe_index_url =  do
  let
	visible_hmods = filter visible hmods
	visible i = OptHide `notElem` hmod_options i

  when (not (isJust maybe_contents_url)) $ 
    ppHtmlContents odir doctitle maybe_package
        maybe_html_help_format maybe_index_url maybe_source_url maybe_wiki_url
	[ hmod { hmod_package = Nothing } | hmod <- visible_hmods ]
	-- we don't want to display the packages in a single-package contents
	prologue

  when (not (isJust maybe_index_url)) $ 
    ppHtmlIndex odir doctitle maybe_package maybe_html_help_format
      maybe_contents_url maybe_source_url maybe_wiki_url visible_hmods
    
  when (not (isJust maybe_contents_url && isJust maybe_index_url)) $ 
	ppHtmlHelpFiles doctitle maybe_package hmods odir maybe_html_help_format []

  mapM_ (ppHtmlModule odir doctitle
	   maybe_source_url maybe_wiki_url
	   maybe_contents_url maybe_index_url) visible_hmods

ppHtmlHelpFiles	
    :: String                   -- doctitle
    -> Maybe String				-- package
	-> [HaddockModule]
	-> FilePath                 -- destination directory
	-> Maybe String             -- the Html Help format (--html-help)
	-> [FilePath]               -- external packages paths
	-> IO ()
ppHtmlHelpFiles doctitle maybe_package hmods odir maybe_html_help_format pkg_paths =  do
  let
	visible_hmods = filter visible hmods
	visible i = OptHide `notElem` hmod_options i

  -- Generate index and contents page for Html Help if requested
  case maybe_html_help_format of
    Nothing        -> return ()
    Just "mshelp"  -> ppHHProject odir doctitle maybe_package visible_hmods pkg_paths
    Just "mshelp2" -> do
		ppHH2Files      odir maybe_package visible_hmods pkg_paths
		ppHH2Collection odir doctitle maybe_package
    Just "devhelp" -> ppDevHelpFile odir doctitle maybe_package visible_hmods
    Just format    -> fail ("The "++format++" format is not implemented")

copyFile :: FilePath -> FilePath -> IO ()
copyFile fromFPath toFPath =
	(bracket (openBinaryFile fromFPath ReadMode) hClose $ \hFrom ->
	 bracket (openBinaryFile toFPath WriteMode) hClose $ \hTo ->
	 allocaBytes bufferSize $ \buffer ->
		copyContents hFrom hTo buffer)
	where
		bufferSize = 1024
		
		copyContents hFrom hTo buffer = do
			count <- hGetBuf hFrom buffer bufferSize
			when (count > 0) $ do
				hPutBuf hTo buffer count
				copyContents hFrom hTo buffer


copyHtmlBits :: FilePath -> FilePath -> Maybe FilePath -> IO ()
copyHtmlBits odir libdir maybe_css = do
  let 
	libhtmldir = pathJoin [libdir, "html"]
	css_file = case maybe_css of
			Nothing -> pathJoin [libhtmldir, cssFile]
			Just f  -> f
	css_destination = pathJoin [odir, cssFile]
	copyLibFile f = do
	   copyFile (pathJoin [libhtmldir, f]) (pathJoin [odir, f])
 
  copyFile css_file css_destination
  mapM_ copyLibFile [ iconFile, plusFile, minusFile, jsFile ]

footer :: HtmlTable
footer = 
  tda [theclass "botbar"] << 
	( toHtml "Produced by" <+> 
	  (anchor ! [href projectUrl] << toHtml projectName) <+>
	  toHtml ("version " ++ projectVersion)
	)
   
srcButton :: SourceURLs -> Maybe HaddockModule -> HtmlTable
srcButton (Just src_base_url, _, _) Nothing =
  topButBox (anchor ! [href src_base_url] << toHtml "Source code")

srcButton (_, Just src_module_url, _) (Just hmod) =
  let url = spliceURL (Just $ hmod_orig_filename hmod)
                      (Just $ hmod_mod hmod) Nothing src_module_url
   in topButBox (anchor ! [href url] << toHtml "Source code")

srcButton _ _ =
  Html.emptyTable
 
spliceURL :: Maybe FilePath -> Maybe Module -> Maybe GHC.Name -> String -> String
spliceURL maybe_file maybe_mod maybe_name url = run url
 where
  file = fromMaybe "" maybe_file
  mod = case maybe_mod of
          Nothing           -> ""
          Just mod -> moduleString mod  
  
  (name, kind) =
    case maybe_name of
      Nothing             -> ("","")
      Just n | isValOcc (nameOccName n) -> (escapeStr (getOccString n), "v")
             | otherwise -> (escapeStr (getOccString n), "t")

  run "" = ""
  run ('%':'M':rest) = mod ++ run rest
  run ('%':'F':rest) = file ++ run rest
  run ('%':'N':rest) = name ++ run rest
  run ('%':'K':rest) = kind ++ run rest

  run ('%':'{':'M':'O':'D':'U':'L':'E':'}':rest) = mod ++ run rest
  run ('%':'{':'F':'I':'L':'E':'}':rest)         = file ++ run rest
  run ('%':'{':'N':'A':'M':'E':'}':rest)         = name ++ run rest
  run ('%':'{':'K':'I':'N':'D':'}':rest)         = kind ++ run rest

  run ('%':'{':'M':'O':'D':'U':'L':'E':'/':'.':'/':c:'}':rest) =
    map (\x -> if x == '.' then c else x) mod ++ run rest

  run (c:rest) = c : run rest
  
wikiButton :: WikiURLs -> Maybe Module -> HtmlTable
wikiButton (Just wiki_base_url, _, _) Nothing =
  topButBox (anchor ! [href wiki_base_url] << toHtml "User Comments")

wikiButton (_, Just wiki_module_url, _) (Just mod) =
  let url = spliceURL Nothing (Just mod) Nothing wiki_module_url
   in topButBox (anchor ! [href url] << toHtml "User Comments")

wikiButton _ _ =
  Html.emptyTable

contentsButton :: Maybe String -> HtmlTable
contentsButton maybe_contents_url 
  = topButBox (anchor ! [href url] << toHtml "Contents")
  where url = case maybe_contents_url of
			Nothing -> contentsHtmlFile
			Just url -> url

indexButton :: Maybe String -> HtmlTable
indexButton maybe_index_url 
  = topButBox (anchor ! [href url] << toHtml "Index")
  where url = case maybe_index_url of
			Nothing -> indexHtmlFile
			Just url -> url

simpleHeader :: String -> Maybe String -> Maybe String
             -> SourceURLs -> WikiURLs -> HtmlTable
simpleHeader doctitle maybe_contents_url maybe_index_url
  maybe_source_url maybe_wiki_url = 
  (tda [theclass "topbar"] << 
     vanillaTable << (
       (td << 
  	image ! [src "haskell_icon.gif", width "16", height 16, alt " " ]
       ) <->
       (tda [theclass "title"] << toHtml doctitle) <->
	srcButton maybe_source_url Nothing <->
        wikiButton maybe_wiki_url Nothing <->
	contentsButton maybe_contents_url <-> indexButton maybe_index_url
   ))

pageHeader :: String -> HaddockModule -> String
    -> SourceURLs -> WikiURLs
    -> Maybe String -> Maybe String -> HtmlTable
pageHeader mdl hmod doctitle
           maybe_source_url maybe_wiki_url
           maybe_contents_url maybe_index_url =
  (tda [theclass "topbar"] << 
    vanillaTable << (
       (td << 
  	image ! [src "haskell_icon.gif", width "16", height 16, alt " "]
       ) <->
       (tda [theclass "title"] << toHtml doctitle) <->
	srcButton maybe_source_url (Just hmod) <->
	wikiButton maybe_wiki_url (Just $ hmod_mod hmod) <->
	contentsButton maybe_contents_url <->
	indexButton maybe_index_url
    )
   ) </>
   tda [theclass "modulebar"] <<
	(vanillaTable << (
	  (td << font ! [size "6"] << toHtml mdl) <->
	  moduleInfo hmod
	)
    )

moduleInfo :: HaddockModule -> HtmlTable
moduleInfo hmod = 
   let
      info = hmod_info hmod

      doOneEntry :: (String, (GHC.HaddockModInfo GHC.Name) -> Maybe String) -> Maybe HtmlTable
      doOneEntry (fieldName,field) = case field info of
         Nothing -> Nothing
         Just fieldValue -> 
            Just ((tda [theclass "infohead"] << toHtml fieldName)
               <-> (tda [theclass "infoval"]) << toHtml fieldValue)
     
      entries :: [HtmlTable]
      entries = mapMaybe doOneEntry [
         ("Portability",GHC.hmi_portability),
         ("Stability",GHC.hmi_stability),
         ("Maintainer",GHC.hmi_maintainer)
         ]
   in
      case entries of
         [] -> Html.emptyTable
         _ -> tda [align "right"] << narrowTable << (foldl1 (</>) entries)

-- ---------------------------------------------------------------------------
-- Generate the module contents

ppHtmlContents
   :: FilePath
   -> String
   -> Maybe String
   -> Maybe String
   -> Maybe String
   -> SourceURLs
   -> WikiURLs
   -> [HaddockModule] -> Maybe (GHC.HsDoc GHC.RdrName)
   -> IO ()
ppHtmlContents odir doctitle
  maybe_package maybe_html_help_format maybe_index_url
  maybe_source_url maybe_wiki_url modules prologue = do
  let tree = mkModuleTree 
         [(hmod_mod mod, hmod_package mod, toDescription mod) | mod <- modules]
      html = 
	header 
		(documentCharacterEncoding +++
		 thetitle (toHtml doctitle) +++
		 styleSheet +++
		 (script ! [src jsFile, thetype "text/javascript"] $ noHtml)) +++
        body << vanillaTable << (
   	    simpleHeader doctitle Nothing maybe_index_url
                         maybe_source_url maybe_wiki_url </>
	    ppPrologue doctitle prologue </>
	    ppModuleTree doctitle tree </>
	    s15 </>
	    footer
	  )
  writeFile (pathJoin [odir, contentsHtmlFile]) (renderHtml html)
  
  -- Generate contents page for Html Help if requested
  case maybe_html_help_format of
    Nothing        -> return ()
    Just "mshelp"  -> ppHHContents  odir doctitle maybe_package tree
    Just "mshelp2" -> ppHH2Contents odir doctitle maybe_package tree
    Just "devhelp" -> return ()
    Just format    -> fail ("The "++format++" format is not implemented")

ppPrologue :: String -> Maybe (GHC.HsDoc GHC.RdrName) -> HtmlTable
ppPrologue title Nothing = Html.emptyTable
ppPrologue title (Just doc) = 
  (tda [theclass "section1"] << toHtml title) </>
  docBox (rdrDocToHtml doc)

ppModuleTree :: String -> [ModuleTree] -> HtmlTable
ppModuleTree _ ts = 
  tda [theclass "section1"] << toHtml "Modules" </>
  td << vanillaTable2 << htmlTable
  where
    genTable htmlTable id []     = (htmlTable,id)
    genTable htmlTable id (x:xs) = genTable (htmlTable </> u) id' xs      
      where
        (u,id') = mkNode [] x 0 id

    (htmlTable,_) = genTable emptyTable 0 ts

mkNode :: [String] -> ModuleTree -> Int -> Int -> (HtmlTable,Int)
mkNode ss (Node s leaf pkg short ts) depth id = htmlNode
  where
    htmlNode = case ts of
      [] -> (td_pad_w 1.25 depth << htmlModule  <-> shortDescr <-> htmlPkg,id)
      _  -> (td_w depth << (collapsebutton id_s +++ htmlModule) <-> shortDescr <-> htmlPkg </> 
                (td_subtree << sub_tree), id')

    mod_width = 50::Int {-em-}

    td_pad_w pad depth = 
	tda [thestyle ("padding-left: " ++ show pad ++ "em;" ++
		       "width: " ++ show (mod_width - depth*2) ++ "em")]

    td_w depth = 
	tda [thestyle ("width: " ++ show (mod_width - depth*2) ++ "em")]

    td_subtree =
	tda [thestyle ("padding: 0; padding-left: 2em")]

    shortDescr :: HtmlTable
    shortDescr = case short of
	Nothing -> td empty
	Just doc -> tda [theclass "rdoc"] (origDocToHtml doc)

    htmlModule 
      | leaf      = ppModule mdl
      | otherwise = toHtml s

    htmlPkg = case pkg of
      Nothing -> td << empty
      Just p  -> td << toHtml p

    mdl = foldr (++) "" (s' : map ('.':) ss')
    (s':ss') = reverse (s:ss)
	 -- reconstruct the module name
    
    id_s = "n:" ++ show id
    
    (sub_tree,id') = genSubTree emptyTable (id+1) ts
    
    genSubTree :: HtmlTable -> Int -> [ModuleTree] -> (Html,Int)
    genSubTree htmlTable id [] = (sub_tree,id)
      where
        sub_tree = collapsed vanillaTable2 id_s htmlTable
    genSubTree htmlTable id (x:xs) = genSubTree (htmlTable </> u) id' xs      
      where
        (u,id') = mkNode (s:ss) x (depth+1) id

-- The URL for source and wiki links, and the current module
type LinksInfo = (SourceURLs, WikiURLs, HaddockModule)


-- ---------------------------------------------------------------------------
-- Generate the index

ppHtmlIndex :: FilePath
            -> String 
            -> Maybe String
            -> Maybe String
            -> Maybe String
            -> SourceURLs
            -> WikiURLs
            -> [HaddockModule] 
            -> IO ()
ppHtmlIndex odir doctitle maybe_package maybe_html_help_format
  maybe_contents_url maybe_source_url maybe_wiki_url modules = do
  let html = 
	header (documentCharacterEncoding +++
		thetitle (toHtml (doctitle ++ " (Index)")) +++
		styleSheet) +++
        body << vanillaTable << (
	    simpleHeader doctitle maybe_contents_url Nothing
                         maybe_source_url maybe_wiki_url </>
	    index_html
	   )

  when split_indices $
    mapM_ (do_sub_index index) initialChars

  writeFile (pathJoin [odir, indexHtmlFile]) (renderHtml html)
  
    -- Generate index and contents page for Html Help if requested
  case maybe_html_help_format of
    Nothing        -> return ()
    Just "mshelp"  -> ppHHIndex  odir maybe_package modules
    Just "mshelp2" -> ppHH2Index odir maybe_package modules
    Just "devhelp" -> return ()
    Just format    -> fail ("The "++format++" format is not implemented")
 where
  split_indices = length index > 50

  index_html
    | split_indices = 
	tda [theclass "section1"] << 
	      	toHtml ("Index") </>
	indexInitialLetterLinks
   | otherwise =
	td << table ! [cellpadding 0, cellspacing 5] <<
	  aboves (map indexElt index) 
 	
  indexInitialLetterLinks = 
	td << table ! [cellpadding 0, cellspacing 5] <<
	    besides [ td << anchor ! [href (subIndexHtmlFile c)] <<
			 toHtml [c]
		    | c <- initialChars
                    , any ((==c) . toUpper . head . fst) index ]

  do_sub_index this_ix c
    = unless (null index_part) $
        writeFile (pathJoin [odir, subIndexHtmlFile c]) (renderHtml html)
    where 
      html = header (documentCharacterEncoding +++
		thetitle (toHtml (doctitle ++ " (Index)")) +++
		styleSheet) +++
             body << vanillaTable << (
	        simpleHeader doctitle maybe_contents_url Nothing
                             maybe_source_url maybe_wiki_url </>
		indexInitialLetterLinks </>
	        tda [theclass "section1"] << 
	      	toHtml ("Index (" ++ c:")") </>
	        td << table ! [cellpadding 0, cellspacing 5] <<
	      	  aboves (map indexElt index_part) 
	       )

      index_part = [(n,stuff) | (n,stuff) <- this_ix, toUpper (head n) == c]

  index :: [(String, Map GHC.Name [(Module,Bool)])]
  index = sortBy cmp (Map.toAscList full_index)
    where cmp (n1,_) (n2,_) = n1 `compare` n2

  -- for each name (a plain string), we have a number of original HsNames that
  -- it can refer to, and for each of those we have a list of modules
  -- that export that entity.  Each of the modules exports the entity
  -- in a visible or invisible way (hence the Bool).
  full_index :: Map String (Map GHC.Name [(Module,Bool)])
  full_index = Map.fromListWith (flip (Map.unionWith (++)))
		(concat (map getHModIndex modules))

  getHModIndex hmod = 
    [ (getOccString name, 
	Map.fromList [(name, [(mdl, name `elem` hmod_visible_exports hmod)])])
    | name <- hmod_exports hmod ]
    where mdl = hmod_mod hmod

  indexElt :: (String, Map GHC.Name [(Module,Bool)]) -> HtmlTable
  indexElt (str, entities) = 
     case Map.toAscList entities of
	[(nm,entries)] ->  
	    tda [ theclass "indexentry" ] << toHtml str <-> 
			indexLinks nm entries
	many_entities ->
	    tda [ theclass "indexentry" ] << toHtml str </> 
		aboves (map doAnnotatedEntity (zip [1..] many_entities))

  doAnnotatedEntity (j,(nm,entries))
	= tda [ theclass "indexannot" ] << 
		toHtml (show j) <+> parens (ppAnnot (nameOccName nm)) <->
		 indexLinks nm entries

  ppAnnot n | not (isValOcc n) = toHtml "Type/Class"
            | isDataOcc n      = toHtml "Data Constructor"
            | otherwise        = toHtml "Function"

  indexLinks nm entries = 
     tda [ theclass "indexlinks" ] << 
	hsep (punctuate comma 
	[ if visible then
	     linkId mod (Just nm) << toHtml (moduleString mod)
	  else
	     toHtml (moduleString mod)
	| (mod, visible) <- entries ])

  initialChars = [ 'A'..'Z' ] ++ ":!#$%&*+./<=>?@\\^|-~"

-- ---------------------------------------------------------------------------
-- Generate the HTML page for a module

ppHtmlModule
	:: FilePath -> String
	-> SourceURLs -> WikiURLs
	-> Maybe String -> Maybe String
	-> HaddockModule -> IO ()
ppHtmlModule odir doctitle
  maybe_source_url maybe_wiki_url
  maybe_contents_url maybe_index_url hmod = do
  let 
      mod = hmod_mod hmod
      mdl = moduleString mod
      html = 
	header (documentCharacterEncoding +++
		thetitle (toHtml mdl) +++
		styleSheet +++
		(script ! [src jsFile, thetype "text/javascript"] $ noHtml)) +++
        body << vanillaTable << (
	    pageHeader mdl hmod doctitle
		maybe_source_url maybe_wiki_url
		maybe_contents_url maybe_index_url </> s15 </>
	    hmodToHtml maybe_source_url maybe_wiki_url hmod </> s15 </>
	    footer
         )
  writeFile (pathJoin [odir, moduleHtmlFile mdl]) (renderHtml html)

hmodToHtml :: SourceURLs -> WikiURLs -> HaddockModule -> HtmlTable
hmodToHtml maybe_source_url maybe_wiki_url hmod
  = abovesSep s15 (contents: description: synopsis: maybe_doc_hdr: bdy)
  where
        docMap = hmod_rn_doc_map hmod
 
	exports = numberSectionHeadings (hmod_rn_export_items hmod)

	has_doc (ExportDecl2 _ _ doc _) = isJust doc
	has_doc (ExportNoDecl2 _ _ _) = False
	has_doc (ExportModule2 _) = False
	has_doc _ = True

	no_doc_at_all = not (any has_doc exports)

	contents = td << vanillaTable << ppModuleContents exports

	description
          = case hmod_rn_doc hmod of
              Nothing -> Html.emptyTable
              Just doc -> (tda [theclass "section1"] << toHtml "Description") </>
                          docBox (docToHtml doc)

	-- omit the synopsis if there are no documentation annotations at all
	synopsis
	  | no_doc_at_all = Html.emptyTable
	  | otherwise
	  = (tda [theclass "section1"] << toHtml "Synopsis") </>
	    s15 </>
            (tda [theclass "body"] << vanillaTable <<
  	        abovesSep s8 (map (processExport True linksInfo docMap)
			(filter forSummary exports))
	    )

	-- if the documentation doesn't begin with a section header, then
	-- add one ("Documentation").
	maybe_doc_hdr
	    = case exports of		   
		   [] -> Html.emptyTable
		   ExportGroup2 _ _ _ : _ -> Html.emptyTable
		   _ -> tda [ theclass "section1" ] << toHtml "Documentation"

	bdy  = map (processExport False linksInfo docMap) exports
	linksInfo = (maybe_source_url, maybe_wiki_url, hmod)

ppModuleContents :: [ExportItem2 DocName] -> HtmlTable
ppModuleContents exports
  | length sections == 0 = Html.emptyTable
  | otherwise            = tda [theclass "section4"] << bold << toHtml "Contents"
  		           </> td << dlist << concatHtml sections
 where
  (sections, _leftovers{-should be []-}) = process 0 exports

  process :: Int -> [ExportItem2 DocName] -> ([Html],[ExportItem2 DocName])
  process _ [] = ([], [])
  process n items@(ExportGroup2 lev id0 doc : rest) 
    | lev <= n  = ( [], items )
    | otherwise = ( html:secs, rest2 )
    where
	html = (dterm << linkedAnchor id0 << docToHtml doc)
		 +++ mk_subsections ssecs
	(ssecs, rest1) = process lev rest
	(secs,  rest2) = process n   rest1
  process n (_ : rest) = process n rest

  mk_subsections [] = noHtml
  mk_subsections ss = ddef << dlist << concatHtml ss

-- we need to assign a unique id to each section heading so we can hyperlink
-- them from the contents:
numberSectionHeadings :: [ExportItem2 DocName] -> [ExportItem2 DocName]
numberSectionHeadings exports = go 1 exports
  where go :: Int -> [ExportItem2 DocName] -> [ExportItem2 DocName]
        go _ [] = []
	go n (ExportGroup2 lev _ doc : es) 
	  = ExportGroup2 lev (show n) doc : go (n+1) es
	go n (other:es)
	  = other : go n es

processExport :: Bool -> LinksInfo -> DocMap -> (ExportItem2 DocName) -> HtmlTable
processExport _ _ _ (ExportGroup2 lev id0 doc)
  = ppDocGroup lev (namedAnchor id0 << docToHtml doc)
processExport summary links docMap (ExportDecl2 x decl doc insts)
  = doDecl summary links x decl doc insts docMap
processExport summmary _ _ (ExportNoDecl2 _ y [])
  = declBox (ppDocName y)
processExport summmary _ _ (ExportNoDecl2 _ y subs)
  = declBox (ppDocName y <+> parenList (map ppDocName subs))
processExport _ _ _ (ExportDoc2 doc)
  = docBox (docToHtml doc)
processExport _ _ _ (ExportModule2 mod)
  = declBox (toHtml "module" <+> ppModule (moduleString mod))

forSummary :: (ExportItem2 DocName) -> Bool
forSummary (ExportGroup2 _ _ _) = False
forSummary (ExportDoc2 _)       = False
forSummary _                    = True

ppDocGroup :: Int -> Html -> HtmlTable
ppDocGroup lev doc
  | lev == 1  = tda [ theclass "section1" ] << doc
  | lev == 2  = tda [ theclass "section2" ] << doc
  | lev == 3  = tda [ theclass "section3" ] << doc
  | otherwise = tda [ theclass "section4" ] << doc

declWithDoc :: Bool -> LinksInfo -> SrcSpan -> Name -> Maybe (HsDoc DocName) -> Html -> HtmlTable
declWithDoc True  _     _   _  _          html_decl = declBox html_decl
declWithDoc False links loc nm Nothing    html_decl = topDeclBox links loc nm html_decl
declWithDoc False links loc nm (Just doc) html_decl = 
		topDeclBox links loc nm html_decl </> docBox (docToHtml doc)

doDecl :: Bool -> LinksInfo -> Name -> LHsDecl DocName -> 
          Maybe (HsDoc DocName) -> [InstHead2 DocName] -> DocMap -> HtmlTable
doDecl summary links x (L loc d) mbDoc instances docMap = doDecl d
  where
    doDecl (TyClD d) = doTyClD d 
    doDecl (SigD s) = ppSig summary links loc mbDoc s
    doDecl (ForD d) = ppFor summary links loc mbDoc d

    doTyClD d0@(TyData {}) = ppDataDecl summary links instances x mbDoc d0
    doTyClD d0@(TySynonym {}) = ppTySyn summary links loc mbDoc d0
    doTyClD d0@(ClassDecl {}) = ppClassDecl summary links instances x loc mbDoc docMap d0

ppSig :: Bool -> LinksInfo -> SrcSpan -> Maybe (HsDoc DocName) -> Sig DocName -> HtmlTable
ppSig summary links loc mbDoc (TypeSig lname ltype) 
  | summary || noArgDocs t = 
    declWithDoc summary links loc n mbDoc (ppTypeSig summary n t)
  | otherwise = topDeclBox links loc n (ppHsBinder False n) </>
    (tda [theclass "body"] << vanillaTable <<  (
      do_args dcolon t </>
        (case mbDoc of 
          Just doc -> ndocBox (docToHtml doc)
          Nothing -> Html.emptyTable)
	))

  where 
  t = unLoc ltype
  NoLink n = unLoc lname

  noLArgDocs (L _ t) = noArgDocs t
  noArgDocs (HsForAllTy _ _ _ t) = noLArgDocs t
  noArgDocs (HsFunTy (L _ (HsDocTy _ _)) _) = False 
  noArgDocs (HsFunTy _ r) = noLArgDocs r
  noArgDocs (HsDocTy _ _) = False
  noArgDocs _ = True

  do_largs leader (L _ t) = do_args leader t  
  do_args :: Html -> (HsType DocName) -> HtmlTable
  do_args leader (HsForAllTy Explicit tvs lctxt ltype)
    = (argBox (
        leader <+> 
        hsep (keyword "forall" : ppTyVars tvs ++ [toHtml "."]) <+>
        ppLContext lctxt)
          <-> rdocBox noHtml) </> 
          do_largs darrow ltype
  do_args leader (HsForAllTy Implicit _ lctxt ltype)
    = (argBox (leader <+> ppLContext lctxt)
        <-> rdocBox noHtml) </> 
        do_largs darrow ltype
  do_args leader (HsFunTy (L _ (HsDocTy lt ldoc)) r)
    = (argBox (leader <+> ppLType lt) <-> rdocBox (docToHtml (unLoc ldoc)))
        </> do_largs arrow r
  do_args leader (HsFunTy lt r)
    = (argBox (leader <+> ppLType lt) <-> rdocBox noHtml) </> do_largs arrow r
  do_args leader (HsDocTy lt ldoc)
    = (argBox (leader <+> ppLType lt) <-> rdocBox (docToHtml (unLoc ldoc)))
  do_args leader t
    = argBox (leader <+> ppType t) <-> rdocBox (noHtml)

ppTyVars tvs = map ppName (tyvarNames tvs)

tyvarNames = map f 
  where f x = let NoLink n = hsTyVarName (unLoc x) in n
  
ppFor = undefined
ppDataDecl = undefined

ppTySyn summary links loc mbDoc (TySynonym lname ltyvars ltype) 
  = declWithDoc summary links loc n mbDoc (
    hsep ([keyword "type", ppHsBinder summary n]
    ++ ppTyVars ltyvars) <+> equals <+> ppLType ltype)
  where NoLink n = unLoc lname

ppLType (L _ t) = ppType t

ppLContext (L _ c) = ppContext c

ppContext = ppPreds . (map unLoc)

ppPreds []     = empty
ppPreds [pred] = ppPred pred
ppPreds preds  = parenList (map ppPred preds)

ppPred (HsClassP n ts) = ppDocName n <+> hsep (map ppLType ts)
ppPred (HsIParam (Dupable n) t) 
  = toHtml "?" +++ ppDocName n <+> dcolon <+> ppLType t
ppPred (HsIParam (Linear  n) t) 
  = toHtml "%" +++ ppDocName n <+> dcolon <+> ppLType t

ppTypeSig :: Bool -> Name -> (HsType DocName) -> Html
ppTypeSig summary nm ty = ppHsBinder summary nm <+> dcolon <+> ppType ty

-- -----------------------------------------------------------------------------
-- Class declarations

--ppClassHdr :: Bool -> HsContext -> HsName -> [HsName] -> [HsFunDep] -> Html
ppClassHdr summ (L _ []) n tvs fds = 
  keyword "class"
	<+> ppHsBinder summ n <+> hsep (ppTyVars tvs)
	<+> ppFds fds
ppClassHdr summ lctxt n tvs fds = 
  keyword "class" <+> ppLContext lctxt <+> darrow
	<+> ppHsBinder summ n <+> hsep (ppTyVars tvs)
	<+> ppFds fds

--ppFds :: [HsFunDep] -> Html
ppFds fds =
  if null fds then noHtml else 
	char '|' <+> hsep (punctuate comma (map (fundep . unLoc) fds))
  where
	fundep (vars1,vars2) = hsep (map ppDocName vars1) <+> toHtml "->" <+>
			       hsep (map ppDocName vars2)

ppShortClassDecl :: Bool -> LinksInfo -> TyClDecl DocName -> SrcSpan -> DocMap -> HtmlTable
ppShortClassDecl summary links (ClassDecl lctxt lname tvs fds sigs _ _) loc docMap = 
  if null sigs
    then (if summary then declBox else topDeclBox links loc nm) hdr
    else (if summary then declBox else topDeclBox links loc nm) (hdr <+> keyword "where")
	    </> 
           (tda [theclass "body"] << 
	     vanillaTable << 
	       aboves [ ppSig summary links loc mbDoc sig  
		      | L _ sig@(TypeSig (L _ (NoLink n)) ty) <- sigs, let mbDoc = Map.lookup n docMap ]
          )
  where
    hdr = ppClassHdr summary lctxt nm tvs fds
    NoLink nm = unLoc lname

ppClassDecl :: Ord key => Bool -> LinksInfo -> [InstHead2 DocName] -> key -> SrcSpan ->
                          Maybe (HsDoc DocName) -> DocMap -> TyClDecl DocName -> 
                          HtmlTable
ppClassDecl summary links instances orig_c loc mbDoc docMap
	decl@(ClassDecl lctxt lname ltyvars lfds lsigs _ _)
  | summary = ppShortClassDecl summary links decl loc docMap
  | otherwise
    = classheader </>
      tda [theclass "body"] << vanillaTable << (
        classdoc </> methods_bit </> instances_bit
      )
  where 
    classheader
      | null lsigs = topDeclBox links loc nm hdr
      | otherwise  = topDeclBox links loc nm (hdr <+> keyword "where")

    NoLink nm = unLoc lname
    ctxt = unLoc lctxt

    hdr = ppClassHdr summary lctxt nm ltyvars lfds
    
    classdoc = case mbDoc of
      Nothing -> Html.emptyTable
      Just d -> ndocBox (docToHtml d)

    methods_bit
      | null lsigs = Html.emptyTable
      | otherwise  = 
        s8 </> meth_hdr </>
        tda [theclass "body"] << vanillaTable << (
          abovesSep s8 [ ppSig summary links loc mbDoc sig
                         | L _ sig@(TypeSig (L _ (NoLink n)) t) <- lsigs, let mbDoc = Map.lookup n docMap ]
        )

    inst_id = collapseId nm
    instances_bit
      | null instances = Html.emptyTable
      | otherwise 
        =  s8 </> inst_hdr inst_id </>
           tda [theclass "body"] << 
             collapsed thediv inst_id (
             spacedTable1 << (
               aboves (map (declBox.ppInstHead) instances)
             ))

ppInstHead :: InstHead2 DocName -> Html
ppInstHead ([],   n, ts) = ppAsst n ts 
ppInstHead (ctxt, n, ts) = ppPreds ctxt <+> ppAsst n ts 

ppAsst n ts = ppDocName n <+> hsep (map ppType ts)

{-
-- -----------------------------------------------------------------------------
-- Converting declarations to HTML

declWithDoc :: Bool -> LinksInfo -> SrcLoc -> HsName -> Maybe Doc -> Html -> HtmlTable
declWithDoc True  _     _   _  _          html_decl = declBox html_decl
declWithDoc False links loc nm Nothing    html_decl = topDeclBox links loc nm html_decl
declWithDoc False links loc nm (Just doc) html_decl = 
		topDeclBox links loc nm html_decl </> docBox (docToHtml doc)

doDecl :: Bool -> LinksInfo -> HsQName -> HsDecl -> [InstHead] -> HtmlTable
doDecl summary links x d instances = do_decl d
  where
     do_decl (HsTypeSig loc [nm] ty doc) 
	= ppFunSig summary links loc nm ty doc

     do_decl (HsForeignImport loc _ _ _ n ty doc)
	= ppFunSig summary links loc n ty doc

     do_decl (HsTypeDecl loc nm args ty doc)
	= declWithDoc summary links loc nm doc (
	      hsep ([keyword "type", ppHsBinder summary nm]
		 ++ map ppHsName args) <+> equals <+> ppHsType ty)

     do_decl (HsNewTypeDecl loc ctx nm args con drv doc)
	= ppHsDataDecl summary links instances True{-is newtype-} x
		(HsDataDecl loc ctx nm args [con] drv doc)
	  -- print it as a single-constructor datatype

     do_decl d0@(HsDataDecl{})
	= ppHsDataDecl summary links instances False{-not newtype-} x d0

     do_decl d0@(HsClassDecl{})
	= ppHsClassDecl summary links instances x d0

     do_decl (HsDocGroup _ lev str)
	= if summary then Html.emptyTable 
		     else ppDocGroup lev (docToHtml str)

     do_decl _ = nrror ("do_decl: " ++ show d)


-- -----------------------------------------------------------------------------
-- Data & newtype declarations

ppShortDataDecl :: Bool -> LinksInfo -> Bool -> HsDecl -> Html
ppShortDataDecl summary _ is_newty 
	(HsDataDecl _ _ nm args [con] _ _doc) =
   ppHsDataHeader summary is_newty nm args      
     <+> equals <+> ppShortConstr summary con
ppShortDataDecl summary _ is_newty
	(HsDataDecl _ _ nm args [] _ _doc) = 
   ppHsDataHeader summary is_newty nm args
ppShortDataDecl summary links is_newty
	(HsDataDecl loc _ nm args cons _ _doc) = 
   vanillaTable << (
	(if summary then declBox else topDeclBox links loc nm)
          (ppHsDataHeader summary is_newty nm args) </>
	tda [theclass "body"] << vanillaTable << (
	  aboves (zipWith do_constr ('=':repeat '|') cons)
        )
   )
  where do_constr c con = declBox (toHtml [c] <+> ppShortConstr summary con)
ppShortDataDecl _ _ _ d =
    error $ "HaddockHtml.ppShortDataDecl: unexpected decl " ++ show d

-- The rest of the cases:
ppHsDataDecl :: Ord key => Bool	-> LinksInfo -> [InstHead] -> Bool -> key -> HsDecl -> HtmlTable
ppHsDataDecl summary links instances is_newty 
     x decl@(HsDataDecl loc _ nm args cons _ doc)
  | summary = declWithDoc summary links loc nm doc (ppShortDataDecl summary links is_newty decl)

  | otherwise
        = dataheader </> 
	    tda [theclass "body"] << vanillaTable << (
		datadoc </> 
		constr_bit </>
		instances_bit
            )
  where
	dataheader = topDeclBox links loc nm (ppHsDataHeader False is_newty nm args)

	constr_table
	 	| any isRecDecl cons  = spacedTable5
	  	| otherwise           = spacedTable1

	datadoc | isJust doc = ndocBox (docToHtml (fromJust doc))
	  	| otherwise  = Html.emptyTable

	constr_bit 
		| null cons = Html.emptyTable
		| otherwise = 
			constr_hdr </>
			(tda [theclass "body"] << constr_table << 
			 aboves (map ppSideBySideConstr cons)
			)

	inst_id = collapseId nm

	instances_bit
	   | null instances = Html.emptyTable
	   | otherwise
	   =  inst_hdr inst_id </>
		 tda [theclass "body"] << 
		    collapsed thediv inst_id (
			spacedTable1 << (
			   aboves (map (declBox.ppInstHead) instances)
		        )
 		   )

ppHsDataDecl _ _ _ _ _ d =
    error $ "HaddockHtml.ppHsDataDecl: unexpected decl " ++ show d

isRecDecl :: HsConDecl -> Bool
isRecDecl (HsRecDecl{}) = True
isRecDecl _             = False

ppShortConstr :: Bool -> HsConDecl -> Html
ppShortConstr summary (HsConDecl _ nm tvs ctxt typeList _maybe_doc) = 
   ppHsConstrHdr tvs ctxt +++
	hsep (ppHsBinder summary nm : map ppHsBangType typeList)
ppShortConstr summary (HsRecDecl _ nm tvs ctxt fields _) =
   ppHsConstrHdr tvs ctxt +++
   ppHsBinder summary nm <+>
   braces (vanillaTable << aboves (map (ppShortField summary) fields))

ppHsConstrHdr :: [HsName] -> HsContext -> Html
ppHsConstrHdr tvs ctxt
 = (if null tvs then noHtml else keyword "forall" <+> 
				 hsep (map ppHsName tvs) <+> 
				 toHtml ". ")
   +++
   (if null ctxt then noHtml else ppContext ctxt <+> toHtml "=> ")

ppSideBySideConstr :: HsConDecl -> HtmlTable
ppSideBySideConstr (HsConDecl _ nm tvs ctxt typeList doc) =
  argBox (hsep ((ppHsConstrHdr tvs ctxt +++ 
		ppHsBinder False nm) : map ppHsBangType typeList)) <->
  maybeRDocBox doc
ppSideBySideConstr (HsRecDecl _ nm tvs ctxt fields doc) =
  argBox (ppHsConstrHdr tvs ctxt +++ ppHsBinder False nm) <->
  maybeRDocBox doc </>
  (tda [theclass "body"] << spacedTable1 <<
     aboves (map ppSideBySideField fields))

ppSideBySideField :: HsFieldDecl -> HtmlTable
ppSideBySideField (HsFieldDecl ns ty doc) =
  argBox (hsep (punctuate comma (map (ppHsBinder False) ns))
	   <+> dcolon <+> ppHsBangType ty) <->
  maybeRDocBox doc

{-
ppHsFullConstr :: HsConDecl -> Html
ppHsFullConstr (HsConDecl _ nm tvs ctxt typeList doc) = 
     declWithDoc False doc (
	hsep ((ppHsConstrHdr tvs ctxt +++ 
		ppHsBinder False nm) : map ppHsBangType typeList)
      )
ppHsFullConstr (HsRecDecl _ nm tvs ctxt fields doc) =
   td << vanillaTable << (
     case doc of
       Nothing -> aboves [hdr, fields_html]
       Just _  -> aboves [hdr, constr_doc, fields_html]
   )

  where hdr = declBox (ppHsConstrHdr tvs ctxt +++ ppHsBinder False nm)

	constr_doc	
	  | isJust doc = docBox (docToHtml (fromJust doc))
	  | otherwise  = Html.emptyTable

	fields_html = 
	   td << 
	      table ! [width "100%", cellpadding 0, cellspacing 8] << (
		   aboves (map ppFullField (concat (map expandField fields)))
		)
-}

ppShortField :: Bool -> HsFieldDecl -> HtmlTable
ppShortField summary (HsFieldDecl ns ty _doc) 
  = tda [theclass "recfield"] << (
	  hsep (punctuate comma (map (ppHsBinder summary) ns))
	    <+> dcolon <+> ppHsBangType ty
   )

{-
ppFullField :: HsFieldDecl -> Html
ppFullField (HsFieldDecl [n] ty doc) 
  = declWithDoc False doc (
	ppHsBinder False n <+> dcolon <+> ppHsBangType ty
    )
ppFullField _ = error "ppFullField"

expandField :: HsFieldDecl -> [HsFieldDecl]
expandField (HsFieldDecl ns ty doc) = [ HsFieldDecl [n] ty doc | n <- ns ]
-}

ppHsDataHeader :: Bool -> Bool -> HsName -> [HsName] -> Html
ppHsDataHeader summary is_newty nm args = 
  (if is_newty then keyword "newtype" else keyword "data") <+> 
	ppHsBinder summary nm <+> hsep (map ppHsName args)

ppHsBangType :: HsBangType -> Html
ppHsBangType (HsBangedTy ty) = char '!' +++ ppHsAType ty
ppHsBangType (HsUnBangedTy ty) = ppHsAType ty

-- ----------------------------------------------------------------------------
-- Type signatures

ppFunSig :: Bool -> LinksInfo -> SrcLoc -> HsName -> HsType -> Maybe Doc -> HtmlTable
ppFunSig summary links loc nm ty0 doc
  | summary || no_arg_docs ty0 = 
      declWithDoc summary links loc nm doc (ppTypeSig summary nm ty0)

  | otherwise   = 
	topDeclBox links loc nm (ppHsBinder False nm) </>
	(tda [theclass "body"] << vanillaTable <<  (
	   do_args dcolon ty0 </>
	   (if (isJust doc) 
		then ndocBox (docToHtml (fromJust doc))
		else Html.emptyTable)
	))
  where
	no_arg_docs (HsForAllType _ _ ty) = no_arg_docs ty
	no_arg_docs (HsTyFun (HsTyDoc _ _) _) = False
	no_arg_docs (HsTyFun _ r) = no_arg_docs r
	no_arg_docs (HsTyDoc _ _) = False
 	no_arg_docs _ = True

	do_args :: Html -> HsType -> HtmlTable
	do_args leader (HsForAllType (Just tvs) ctxt ty)
	  = (argBox (
		leader <+> 
		hsep (keyword "forall" : map ppHsName tvs ++ [toHtml "."]) <+>
		ppHsIPContext ctxt)
	      <-> rdocBox noHtml) </> 
	    do_args darrow ty
	do_args leader (HsForAllType Nothing ctxt ty)
	  = (argBox (leader <+> ppHsIPContext ctxt)
		<-> rdocBox noHtml) </> 
	    do_args darrow ty
	do_args leader (HsTyFun (HsTyDoc ty doc0) r)
	  = (argBox (leader <+> ppHsBType ty) <-> rdocBox (docToHtml doc0))
            </> do_args arrow r
	do_args leader (HsTyFun ty r)
	  = (argBox (leader <+> ppHsBType ty) <-> rdocBox noHtml) </>
	    do_args arrow r
	do_args leader (HsTyDoc ty doc0)
	  = (argBox (leader <+> ppHsBType ty) <-> rdocBox (docToHtml doc0))
	do_args leader ty
	  = argBox (leader <+> ppHsBType ty) <-> rdocBox (noHtml)

-}

-- ----------------------------------------------------------------------------
-- Types and contexts

ppKind kind = case kind of
  LiftedTypeKind   -> char '*'
  OpenTypeKind     -> char '?'
  UnboxedTypeKind  -> char '#'
  UnliftedTypeKind -> char '!'
  UbxTupleKind     -> toHtml "(##)"
  ArgTypeKind      -> toHtml "??"
  FunKind k1 k2    -> hsep [ppKind k1, toHtml "->", ppKind k2] 
  KindVar v        -> ppOccName (kindVarOcc v)

ppCtxtPart (L _ ctxt) 
  | null ctxt = empty 
  | otherwise = hsep [ppContext ctxt, darrow]

ppForAll (HsForAllTy Implicit _ lctxt _) = ppCtxtPart lctxt
ppForAll (HsForAllTy Explicit ltvs lctxt _) = 
  hsep (keyword "forall" : ppTyVars ltvs ++ [toHtml "."]) <+> ppCtxtPart lctxt 

ppType :: HsType DocName -> Html
ppType t = case t of
  t@(HsForAllTy expl ltvs lcontext ltype) -> ppForAll t <+> ppLType ltype
  HsTyVar n -> ppDocName n
  HsBangTy HsStrict lt -> toHtml "!" <+> ppLType lt
  HsBangTy HsUnbox lt -> toHtml "!!" <+> ppLType lt
  HsAppTy a b -> ppLType a <+> ppLType b 
  HsFunTy a b -> hsep [ppLType a, toHtml "->", ppLType b]
  HsListTy t -> brackets $ ppLType t
  HsPArrTy t -> toHtml "[:" +++ ppLType t +++ toHtml ":]"
  HsTupleTy Boxed ts -> parenList $ map ppLType ts
  HsTupleTy Unboxed ts -> ubxParenList $ map ppLType ts
  HsOpTy a n b -> ppLType a <+> ppLDocName n <+> ppLType b
  HsParTy t -> parens $ ppLType t
  HsNumTy n -> toHtml (show n)
  HsPredTy p -> ppPred p
  HsKindSig t k -> hsep [ppLType t, dcolon, ppKind k]
  HsSpliceTy _ -> error "ppType"
  HsDocTy t _ -> ppLType t

-- ----------------------------------------------------------------------------
-- Names

ppOccName :: OccName -> Html
ppOccName name = toHtml $ occNameString name

ppRdrName :: RdrName -> Html
ppRdrName = ppOccName . rdrNameOcc

ppLDocName (L _ d) = ppDocName d

ppDocName :: DocName -> Html
ppDocName (Link name) = linkId (nameModule name) (Just name) << ppName name
ppDocName (NoLink name) = toHtml (getOccString name)

linkTarget :: Name -> Html
linkTarget name = namedAnchor (anchorNameStr name) << toHtml "" 

ppName :: Name -> Html
ppName name = toHtml (getOccString name)

ppHsBinder :: Bool -> Name -> Html
-- The Bool indicates whether we are generating the summary, in which case
-- the binder will be a link to the full definition.
ppHsBinder True nm = linkedAnchor (anchorNameStr nm) << ppHsBinder' nm
ppHsBinder False nm = linkTarget nm +++ bold << ppHsBinder' nm

ppHsBinder' :: Name -> Html
ppHsBinder' name = toHtml (getOccString name)

{-
ppHsBinder' :: HsName -> Html
ppHsBinder' (HsTyClsName id0) = ppHsBindIdent id0
ppHsBinder' (HsVarName id0)   = ppHsBindIdent id0

ppHsBindIdent :: HsIdentifier -> Html
ppHsBindIdent (HsIdent str)   =  toHtml str
ppHsBindIdent (HsSymbol str)  =  parens (toHtml str)
ppHsBindIdent (HsSpecial str) =  toHtml str
-}
linkId :: GHC.Module -> Maybe Name -> Html -> Html
linkId mod mbName = anchor ! [href hr]
  where 
    hr = case mbName of
      Nothing   -> moduleHtmlFile modName
      Just name -> nameHtmlRef modName name
    modName = moduleString mod   

ppModule :: String -> Html
ppModule mdl = anchor ! [href ((moduleHtmlFile modname) ++ ref)] << toHtml mdl
  where 
        (modname,ref) = break (== '#') mdl

-- -----------------------------------------------------------------------------
-- * Doc Markup

parHtmlMarkup :: (a -> Html) -> DocMarkup a Html
parHtmlMarkup ppId = Markup {
  markupParagraph     = paragraph,
  markupEmpty	      = toHtml "",
  markupString        = toHtml,
  markupAppend        = (+++),
  markupIdentifier    = tt . ppId . head,
  markupModule        = ppModule,
  markupEmphasis      = emphasize . toHtml,
  markupMonospaced    = tt . toHtml,
  markupUnorderedList = ulist . concatHtml . map (li <<),
  markupOrderedList   = olist . concatHtml . map (li <<),
  markupDefList       = dlist . concatHtml . map markupDef,
  markupCodeBlock     = pre,
  markupURL	      = \url -> anchor ! [href url] << toHtml url,
  markupAName	      = \aname -> namedAnchor aname << toHtml ""
  }

markupDef (a,b) = dterm << a +++ ddef << b

htmlMarkup = parHtmlMarkup ppDocName
htmlOrigMarkup = parHtmlMarkup ppName
htmlRdrMarkup = parHtmlMarkup ppRdrName

-- If the doc is a single paragraph, don't surround it with <P> (this causes
-- ugly extra whitespace with some browsers).
{-docToHtml :: Doc -> Html
docToHtml doc = markup htmlMarkup (unParagraph (markup htmlCleanup doc))
-}
docToHtml :: GHC.HsDoc DocName -> Html
docToHtml doc = markup htmlMarkup (unParagraph (markup htmlCleanup doc))

origDocToHtml :: GHC.HsDoc GHC.Name -> Html
origDocToHtml doc = markup htmlOrigMarkup (unParagraph (markup htmlCleanup doc))

rdrDocToHtml doc = markup htmlRdrMarkup (unParagraph (markup htmlCleanup doc))

-- If there is a single paragraph, then surrounding it with <P>..</P>
-- can add too much whitespace in some browsers (eg. IE).  However if
-- we have multiple paragraphs, then we want the extra whitespace to
-- separate them.  So we catch the single paragraph case and transform it
-- here.
unParagraph (GHC.DocParagraph d) = d
--NO: This eliminates line breaks in the code block:  (SDM, 6/5/2003)
--unParagraph (DocCodeBlock d) = (DocMonospaced d)
unParagraph doc              = doc

htmlCleanup :: DocMarkup a (GHC.HsDoc a)
htmlCleanup = idMarkup { 
  markupUnorderedList = GHC.DocUnorderedList . map unParagraph,
  markupOrderedList   = GHC.DocOrderedList   . map unParagraph
  } 

-- -----------------------------------------------------------------------------
-- * Misc

hsep :: [Html] -> Html
hsep [] = noHtml
hsep htmls = foldr1 (\a b -> a+++" "+++b) htmls

infixr 8 <+>
(<+>) :: Html -> Html -> Html
a <+> b = Html (getHtmlElements (toHtml a) ++ HtmlString " ": getHtmlElements (toHtml b))

keyword :: String -> Html
keyword s = thespan ! [theclass "keyword"] << toHtml s

equals, comma :: Html
equals = char '='
comma  = char ','

char :: Char -> Html
char c = toHtml [c]

empty :: Html
empty  = noHtml

parens, brackets, braces :: Html -> Html
parens h        = char '(' +++ h +++ char ')'
brackets h      = char '[' +++ h +++ char ']'
braces h        = char '{' +++ h +++ char '}'

punctuate :: Html -> [Html] -> [Html]
punctuate _ []     = []
punctuate h (d0:ds) = go d0 ds
                   where
                     go d [] = [d]
                     go d (e:es) = (d +++ h) : go e es

abovesSep :: HtmlTable -> [HtmlTable] -> HtmlTable
abovesSep _ []      = Html.emptyTable
abovesSep h (d0:ds) = go d0 ds
                   where
                     go d [] = d
                     go d (e:es) = d </> h </> go e es

parenList :: [Html] -> Html
parenList = parens . hsep . punctuate comma

ubxParenList :: [Html] -> Html
ubxParenList = ubxparens . hsep . punctuate comma

ubxparens :: Html -> Html
ubxparens h = toHtml "(#" +++ h +++ toHtml "#)"

{-
text :: Html
text   = strAttr "TEXT"
-}

-- a box for displaying code
declBox :: Html -> HtmlTable
declBox html = tda [theclass "decl"] << html

-- a box for top level documented names
-- it adds a source and wiki link at the right hand side of the box
topDeclBox :: LinksInfo -> SrcSpan -> Name -> Html -> HtmlTable
topDeclBox ((_,_,Nothing), (_,_,Nothing), _) _ _ html = declBox html
topDeclBox ((_,_,maybe_source_url), (_,_,maybe_wiki_url), hmod)
           loc name html =
  tda [theclass "topdecl"] <<
  (        table ! [theclass "declbar"] <<
	    ((tda [theclass "declname"] << html)
             <-> srcLink
             <-> wikiLink)
  )
  where srcLink =
          case maybe_source_url of
            Nothing  -> Html.emptyTable
            Just url -> tda [theclass "declbut"] <<
                          let url' = spliceURL (Just fname) (Just mod)
                                               (Just name) url
                           in anchor ! [href url'] << toHtml "Source"
        wikiLink =
          case maybe_wiki_url of
            Nothing  -> Html.emptyTable
            Just url -> tda [theclass "declbut"] <<
                          let url' = spliceURL (Just fname) (Just mod)
                                               (Just name) url
                           in anchor ! [href url'] << toHtml "Comments"
  
        mod = hmod_mod hmod
        fname = unpackFS (srcSpanFile loc)

-- a box for displaying an 'argument' (some code which has text to the
-- right of it).  Wrapping is not allowed in these boxes, whereas it is
-- in a declBox.
argBox :: Html -> HtmlTable
argBox html = tda [theclass "arg"] << html

-- a box for displaying documentation, 
-- indented and with a little padding at the top
docBox :: Html -> HtmlTable
docBox html = tda [theclass "doc"] << html

-- a box for displaying documentation, not indented.
ndocBox :: Html -> HtmlTable
ndocBox html = tda [theclass "ndoc"] << html

-- a box for displaying documentation, padded on the left a little
rdocBox :: Html -> HtmlTable
rdocBox html = tda [theclass "rdoc"] << html

maybeRDocBox :: Maybe (GHC.HsDoc DocName) -> HtmlTable
maybeRDocBox Nothing = rdocBox (noHtml)
maybeRDocBox (Just doc) = rdocBox (docToHtml doc)

-- a box for the buttons at the top of the page
topButBox :: Html -> HtmlTable
topButBox html = tda [theclass "topbut"] << html

-- a vanilla table has width 100%, no border, no padding, no spacing
-- a narrow table is the same but without width 100%.
vanillaTable, narrowTable :: Html -> Html
vanillaTable = table ! [theclass "vanilla", cellspacing 0, cellpadding 0]
vanillaTable2 = table ! [theclass "vanilla2", cellspacing 0, cellpadding 0]
narrowTable  = table ! [theclass "narrow",  cellspacing 0, cellpadding 0]

spacedTable1, spacedTable5 :: Html -> Html
spacedTable1 = table ! [theclass "vanilla",  cellspacing 1, cellpadding 0]
spacedTable5 = table ! [theclass "vanilla",  cellspacing 5, cellpadding 0]

constr_hdr, meth_hdr :: HtmlTable
constr_hdr  = tda [ theclass "section4" ] << toHtml "Constructors"
meth_hdr    = tda [ theclass "section4" ] << toHtml "Methods"

inst_hdr :: String -> HtmlTable
inst_hdr id = 
  tda [ theclass "section4" ] << (collapsebutton id +++ toHtml " Instances")

dcolon, arrow, darrow :: Html
dcolon = toHtml "::"
arrow  = toHtml "->"
darrow = toHtml "=>"

s8, s15 :: HtmlTable
s8  = tda [ theclass "s8" ]  << noHtml
s15 = tda [ theclass "s15" ] << noHtml

namedAnchor :: String -> Html -> Html
namedAnchor n = anchor ! [name (escapeStr n)]

--
-- A section of HTML which is collapsible via a +/- button.
--

-- TODO: Currently the initial state is non-collapsed. Change the 'minusFile'
-- below to a 'plusFile' and the 'display:block;' to a 'display:none;' when we
-- use cookies from JavaScript to have a more persistent state.

collapsebutton :: String -> Html
collapsebutton id = 
  image ! [ src minusFile, theclass "coll", onclick ("toggle(this,'" ++ id ++ "')"), alt "show/hide" ]

collapsed :: (HTML a) => (Html -> Html) -> String -> a -> Html
collapsed fn id html =
  fn ! [identifier id, thestyle "display:block;"] << html

-- A quote is a valid part of a Haskell identifier, but it would interfere with
-- the ECMA script string delimiter used in collapsebutton above.
collapseId :: Name -> String
collapseId nm = "i:" ++ escapeStr (getOccString nm)

linkedAnchor :: String -> Html -> Html
linkedAnchor frag = anchor ! [href hr]
   where hr | null frag = ""
            | otherwise = '#': escapeStr frag

documentCharacterEncoding :: Html
documentCharacterEncoding =
   meta ! [httpequiv "Content-Type", content "text/html; charset=UTF-8"]

styleSheet :: Html
styleSheet =
   thelink ! [href cssFile, rel "stylesheet", thetype "text/css"]
