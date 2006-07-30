{-# OPTIONS_GHC -fglasgow-exts #-}
--
-- Haddock - A Haskell Documentation Tool
--
-- (c) Simon Marlow 2003
--

module Main (main) where

import HsSyn2
import HaddockHtml
import HaddockHoogle
import HaddockRename
import HaddockTypes
import HaddockUtil
import HaddockVersion
import Paths_haddock	( getDataDir )
import Binary2

import Control.Exception ( bracket )
import Control.Monad ( when )
import Control.Monad.Writer ( Writer, runWriter, tell )
import Data.Char ( isSpace )
import Data.IORef ( writeIORef )
import Data.List ( nub, (\\), foldl', sortBy, foldl1 )
import Data.Maybe ( isJust, isNothing, maybeToList, listToMaybe )
--import Debug.Trace
import System.Console.GetOpt ( getOpt, usageInfo, ArgOrder(..), OptDescr(..), ArgDescr(..) )
import System.Environment ( getArgs )
import System.IO ( stderr, IOMode(..), openFile, hClose, hGetContents, hPutStrLn )
#if defined(mingw32_HOST_OS)
import Foreign
import Foreign.C
#endif
import qualified Data.Map as Map
import Data.Map (Map)
import Data.Maybe
import Data.List ( nubBy )

#if __GLASGOW_HASKELL__ >= 603
import System.Process
import System.Exit
import Control.Exception	( Exception(..), throwIO, catch )
import Prelude hiding (catch)
import System.Directory		( doesDirectoryExist, doesFileExist )
import Control.Concurrent
#endif

import qualified GHC as GHC
import Outputable
import SrcLoc
import qualified Digraph as Digraph
import Name
import Module (moduleString)-- TODO: add an export to GHC API? 
import InstEnv
import Class
import TypeRep
import Var
import TyCon
import PrelNames
import FastString
#define FSLIT(x) (mkFastString# (x#))
import qualified DynFlags as DynFlags

-----------------------------------------------------------------------------
-- Top-level stuff
main :: IO ()
main = do
  cmdline <- getArgs
  case getOpt Permute (options True) cmdline of
    (flags, args, []    ) -> run flags args
    (_,     _,    errors) -> do prog <- getProgramName
                                die (concat errors ++
                                     usageInfo (usageHeader prog) (options False))

usageHeader :: String -> String
usageHeader prog = "Usage: " ++ prog ++ " [OPTION...] file...\n"

data Flag
  = Flag_CSS String
  | Flag_Debug
--  | Flag_DocBook
  | Flag_DumpInterface FilePath
  | Flag_Heading String
  | Flag_Package String
  | Flag_Html
  | Flag_Hoogle
  | Flag_HtmlHelp String
  | Flag_Lib String
  | Flag_NoImplicitPrelude
  | Flag_OutputDir FilePath
  | Flag_Prologue FilePath
  | Flag_ReadInterface FilePath
  | Flag_SourceBaseURL   String
  | Flag_SourceModuleURL String
  | Flag_SourceEntityURL String
  | Flag_WikiBaseURL   String
  | Flag_WikiModuleURL String
  | Flag_WikiEntityURL String
  | Flag_Help
  | Flag_Verbose
  | Flag_Version
  | Flag_UseContents String
  | Flag_GenContents
  | Flag_UseIndex String
  | Flag_GenIndex
  | Flag_IgnoreAllExports
  | Flag_HideModule String
  | Flag_UsePackage String
  | Flag_GHCFlag String   
  deriving (Eq)

options :: Bool -> [OptDescr Flag]
options backwardsCompat =
  [ 
    Option ['o']  ["odir"]     (ReqArg Flag_OutputDir "DIR")
	"directory in which to put the output files",
    Option ['i'] ["read-interface"] (ReqArg Flag_ReadInterface "FILE")
	"read an interface from FILE",
    Option ['D']  ["dump-interface"]   (ReqArg Flag_DumpInterface "FILE")
        "dump an interface for these modules in FILE",
    Option ['l']  ["lib"]         (ReqArg Flag_Lib "DIR") 
	"location of Haddock's auxiliary files",
--    Option ['S']  ["docbook"]  (NoArg Flag_DocBook)
--	"output in DocBook XML",
    Option ['h']  ["html"]     (NoArg Flag_Html)
	"output in HTML",
    Option []  ["hoogle"]     (NoArg Flag_Hoogle)
    "output for Hoogle",
    Option []  ["html-help"]    (ReqArg Flag_HtmlHelp "format")
	"produce index and table of contents in\nmshelp, mshelp2 or devhelp format (with -h)",
    Option []  ["source-base"]   (ReqArg Flag_SourceBaseURL "URL") 
	"URL for a source code link on the contents\nand index pages",
    Option ['s'] (if backwardsCompat then ["source", "source-module"] else ["source-module"])
        (ReqArg Flag_SourceModuleURL "URL")
	"URL for a source code link for each module\n(using the %{FILE} or %{MODULE} vars)",
    Option []  ["source-entity"]  (ReqArg Flag_SourceEntityURL "URL") 
	"URL for a source code link for each entity\n(using the %{FILE}, %{MODULE} or %{NAME} vars)",
    Option []  ["comments-base"]   (ReqArg Flag_WikiBaseURL "URL")
	"URL for a comments link on the contents\nand index pages",
    Option []  ["comments-module"]  (ReqArg Flag_WikiModuleURL "URL") 
	"URL for a comments link for each module\n(using the %{MODULE} var)",
    Option []  ["comments-entity"]  (ReqArg Flag_WikiEntityURL "URL") 
	"URL for a comments link for each entity\n(using the %{FILE}, %{MODULE} or %{NAME} vars)",
    Option ['c']  ["css"]         (ReqArg Flag_CSS "FILE") 
	"the CSS file to use for HTML output",
    Option ['p']  ["prologue"] (ReqArg Flag_Prologue "FILE")
	"file containing prologue text",
    Option ['t']  ["title"]    (ReqArg Flag_Heading "TITLE")
	"page heading",
    Option ['k']  ["package"]  (ReqArg Flag_Package "NAME")
	"package name (optional)",
    Option ['n']  ["no-implicit-prelude"] (NoArg Flag_NoImplicitPrelude)
 	"do not assume Prelude is imported",
    Option ['d']  ["debug"]  (NoArg Flag_Debug)
	"extra debugging output",
    Option ['?']  ["help"]  (NoArg Flag_Help)
	"display this help and exit",
    Option ['V']  ["version"]  (NoArg Flag_Version)
	"output version information and exit",
    Option ['v']  ["verbose"]  (NoArg Flag_Verbose)
        "increase verbosity",
    Option [] ["use-contents"] (ReqArg Flag_UseContents "URL")
	"use a separately-generated HTML contents page",
    Option [] ["gen-contents"] (NoArg Flag_GenContents)
	"generate an HTML contents from specified\ninterfaces",
    Option [] ["use-index"] (ReqArg Flag_UseIndex "URL")
	"use a separately-generated HTML index",
    Option [] ["gen-index"] (NoArg Flag_GenIndex)
	"generate an HTML index from specified\ninterfaces",
    Option [] ["ignore-all-exports"] (NoArg Flag_IgnoreAllExports)
	"behave as if all modules have the\nignore-exports atribute",
    Option [] ["hide"] (ReqArg Flag_HideModule "MODULE")
	"behave as if MODULE has the hide attribute",
    Option [] ["use-package"] (ReqArg Flag_UsePackage "PACKAGE")
	"the modules being processed depend on PACKAGE",
    Option [] ["ghc-flag"] (ReqArg Flag_GHCFlag "FLAG")
	"send a one-word FLAG to the Glasgow Haskell Compiler"
  ]

run :: [Flag] -> [FilePath] -> IO ()
run flags files = do
  
  whenFlag Flag_Help $ do
     prog <- getProgramName
     bye (usageInfo (usageHeader prog) (options False))

  whenFlag Flag_Version $
     bye ("Haddock version " ++ projectVersion ++ 
          ", (c) Simon Marlow 2003; port to GHC-api by David Waern 2006\n")

  let title = case [str | Flag_Heading str <- flags] of
		[] -> ""
		(t:_) -> t

      package = listToMaybe [str | Flag_Package str <- flags]

      maybe_source_urls = (listToMaybe [str | Flag_SourceBaseURL   str <- flags]
                          ,listToMaybe [str | Flag_SourceModuleURL str <- flags]
                          ,listToMaybe [str | Flag_SourceEntityURL str <- flags])

      maybe_wiki_urls = (listToMaybe [str | Flag_WikiBaseURL   str <- flags]
                        ,listToMaybe [str | Flag_WikiModuleURL str <- flags]
                        ,listToMaybe [str | Flag_WikiEntityURL str <- flags])

      verbose = Flag_Verbose `elem` flags

  libdir <- case [str | Flag_Lib str <- flags] of
		[] -> getDataDir -- provided by Cabal
		fs -> return (last fs)

  let css_file = case [str | Flag_CSS str <- flags] of
			[] -> Nothing
			fs -> Just (last fs)

  odir <- case [str | Flag_OutputDir str <- flags] of
		[] -> return "."
		fs -> return (last fs)

  let dump_iface = case [str | Flag_DumpInterface str <- flags] of
		  	[] -> Nothing
		  	fs -> Just (last fs)

      read_iface_flags = [ parseIfaceOption str 
		       | Flag_ReadInterface str <- flags ]

      maybe_contents_url = 
	case [url | Flag_UseContents url <- flags] of
		[] -> Nothing
		us -> Just (last us)

      maybe_index_url = 
	case [url | Flag_UseIndex url <- flags] of
		[] -> Nothing
		us -> Just (last us)

      maybe_html_help_format =
	case [hhformat | Flag_HtmlHelp hhformat <- flags] of
		[]      -> Nothing
		formats -> Just (last formats)
		
  prologue <- getPrologue flags

  when ((Flag_GenIndex `elem` flags || Flag_GenContents `elem` flags)
	&& Flag_Html `elem` flags) $
	die ("-h cannot be used with --gen-index or --gen-contents")

  GHC.init (Just "/home/davve/dev/local/lib/ghc-6.5")
  let ghcMode = GHC.JustTypecheck
  session <- GHC.newSession ghcMode
  ghcFlags <- GHC.getSessionDynFlags session
  ghcFlags' <- GHC.initPackages ghcFlags

  let haddockGhcFlags = [ f | Flag_GHCFlag f <- flags ] 
  (ghcFlags'', rest) <- GHC.parseDynamicFlags ghcFlags' haddockGhcFlags 
  when (not (null rest)) (die $ "The following flags are not GHC flags: " ++ pprList rest ++ "\n")
  let ghcFlags''' = DynFlags.dopt_set ghcFlags'' DynFlags.Opt_Haddock 

  sorted_checked_modules <- GHC.defaultErrorHandler ghcFlags''' $ do 
    GHC.setSessionDynFlags session ghcFlags'''
    targets <- mapM (\s -> GHC.guessTarget s Nothing) files
    GHC.setTargets session targets 
    maybe_module_graph <- GHC.depanal session [] True
    module_graph <- case maybe_module_graph of 
      Just module_graph -> return module_graph 
      Nothing -> die "Failed to load modules\n"
    let sorted_modules = concatMap Digraph.flattenSCC (GHC.topSortModuleGraph False module_graph Nothing) 
    let (modules, filenames) = unzip [ (GHC.ms_mod modsum, fromJust $ GHC.ml_hs_file (GHC.ms_location modsum)) | modsum <- sorted_modules,
                                        fromJust (GHC.ml_hs_file (GHC.ms_location modsum)) `elem` files ]

    mb_checked_modules <- mapM (GHC.checkModule session) modules
    let checked_modules = catMaybes mb_checked_modules
    if length checked_modules /= length mb_checked_modules
      then die "Failed to load all modules\n" 
      else return (zip3 modules checked_modules filenames)
  
  sorted_checked_modules' <- remove_maybes sorted_checked_modules

  let (modMap, messages) = runWriter (pass1 sorted_checked_modules' flags package) 

      haddockModules = catMaybes [ Map.lookup mod modMap | 
                                   (mod, _, file) <- sorted_checked_modules',
                                   file `elem` files ]
 
  let env = buildGlobalDocEnv haddockModules

  let haddockModules' = attachInstances haddockModules

  let (renamedModules, messages') = runWriter $ mapM (renameModule env) haddockModules'

  putStrLn "pass 1 messages:"
  print messages
  putStrLn "pass 1 export items:"
  printSDoc (ppr (map hmod_export_items haddockModules')) defaultUserStyle 
  
  putStrLn "pass 2 env:"
  printSDoc (ppr (Map.toList env)) defaultUserStyle

  putStrLn "pass 2 export items:"
  printSDoc (ppr renamedModules) defaultUserStyle 
  mapM_ putStrLn messages'

  let visibleModules = [ m | m <- haddockModules', OptHide `notElem` (hmod_options m) ]
 
  updateHTMLXRefs [] []

  when (Flag_GenIndex `elem` flags) $ do
	ppHtmlIndex odir title package maybe_html_help_format
                maybe_contents_url maybe_source_urls maybe_wiki_urls
                visibleModules
	copyHtmlBits odir libdir css_file
        
  when (Flag_GenContents `elem` flags && Flag_GenIndex `elem` flags) $ do
    ppHtmlHelpFiles title package visibleModules odir maybe_html_help_format []

  when (Flag_GenContents `elem` flags) $ do
	ppHtmlContents odir title package maybe_html_help_format
	               maybe_index_url maybe_source_urls maybe_wiki_urls
	               visibleModules prologue
	copyHtmlBits odir libdir css_file

 
  --let Just (group, imports, exports) = GHC.renamedSource (head sorted_checked_modules)
  --printSDoc (ppr group) defaultUserStyle
   
--  let exports = GHC.modInfoExports $ fromJust $ GHC.checkedModuleInfo $ snd $ (head sorted_checked_modules)
---  printSDoc (ppr exports) defaultUserStyle


                            

{-    let parsed_source = unLoc $ GHC.parsedSource (head checked_modules)
     printSDoc (ppr parsed_source) defaultUserStyle
-}

  return ()
   -- case successFlag of 
    --  GHC.Succeeded -> bye "Succeeded"
    --  GHC.Failed -> bye "Could not load all targets"

{-  parsed_mods <- mapM parse_file files

  sorted_mod_files <- sortModules (zip parsed_mods files)
	-- emits an error message if there are recursive modules

  -- process the modules in sorted order, building up a mapping from
  -- modules to interfaces.
  let 
	loop mod_env ifaces [] = return (reverse ifaces)
	loop mod_env ifaces ((hsmod,file):mdls)  = do 
	   let (iface,msgs) = runWriter $
		   mkInterfacePhase1 flags verbose mod_env file package hsmod
	       new_mod_env = Map.insert (iface_module iface) iface mod_env
	   mapM_ (hPutStrLn stderr) msgs
	   loop new_mod_env (iface:ifaces) mdls

  let 
	mod_map = Map.fromList [ (iface_module iface,iface) 
			       | iface <- read_ifaces ]
  
  ifaces <- loop mod_map read_ifaces sorted_mod_files
  let 
      these_ifaces0 = [ iface | iface <- ifaces,
		    	        iface_module iface `notElem` external_mods ]

  let these_ifaces1  = attachInstances these_ifaces0
      this_doc_env   = buildGlobalDocEnv these_ifaces1
      global_doc_env = this_doc_env `Map.union`
		       ext_doc_env `Map.union`
		       builtinDocEnv


--  Now do phase 2
  let
	loop2 ifaces [] = return (reverse ifaces)
	loop2 ifaces (iface:rest) = do
	   let (iface',msgs) = runWriter $
		    mkInterfacePhase2 verbose iface global_doc_env
	   mapM_ (hPutStrLn stderr) msgs
	   loop2 (iface':ifaces) rest

  these_ifaces <- loop2 [] these_ifaces1  

--  when (Flag_DocBook `elem` flags) $
--    putStr (ppDocBook odir mod_ifaces)


  when (Flag_Debug `elem` flags) $ do
    mapM_ putStrLn (map show [ (iface_module i, 
				     Map.toAscList (iface_env i), 
				     Map.toAscList (iface_sub i))
			     | i <-  these_ifaces ])

  when (Flag_Html `elem` flags) $ do
    ppHtml title package these_ifaces odir
		prologue maybe_html_help_format
		maybe_source_urls maybe_wiki_urls
		maybe_contents_url maybe_index_url
    copyHtmlBits odir libdir css_file

  when (Flag_Hoogle `elem` flags) $ do
    ppHoogle package these_ifaces odir

  -- dump an interface if requested
  case dump_iface of
     Nothing -> return ()
     Just fn -> dumpInterfaces these_ifaces this_doc_env fn -}
  where
    whenFlag flag action = when (flag `elem` flags) action 

    pprList [] = []
    pprList [x] = show x
    pprList (x:xs) = show x ++ ", " ++ pprList xs
 
    remove_maybes modules | length modules' == length modules = return modules'
                          | otherwise = die "Missing checked module phase information\n" 
      where modules' = [ (mod, (a,b,c,d), f) | (mod, GHC.CheckedModule a (Just b) (Just c) (Just d), f) <- modules ] 

print_ x = printSDoc (ppr x) defaultUserStyle        

instance (Outputable a, OutputableBndr a) => Outputable (ExportItem2 a) where
  ppr (ExportDecl2 n decl doc instns) = text "ExportDecl" <+> ppr n <+> ppr decl <+> ppr doc <+> ppr instns
  ppr (ExportNoDecl2 n1 n2 ns) = text "ExportNoDecl (org name, link name, sub names)" <+> ppr n1 <+> ppr n2 <+> ppr ns
  ppr (ExportGroup2 lev id doc) = text "ExportGroup (lev, id, doc)" <+> ppr lev <+> ppr doc
  ppr (ExportDoc2 doc) = text "ExportDoc" <+> ppr doc
  ppr (ExportModule2 mod) = text "ExportModule" <+> ppr mod 	

instance Outputable DocName where
  ppr (Link name) = ppr name
  ppr (NoLink name) = ppr name

instance OutputableBndr DocName where
  pprBndr _ d = ppr d

instance Outputable (GHC.DocEntity GHC.Name) where
  ppr (GHC.DocEntity d) = ppr d
  ppr (GHC.DeclEntity name) = ppr name

type FullyCheckedModule = (GHC.ParsedSource, 
                           GHC.RenamedSource, 
                           GHC.TypecheckedSource, 
                           GHC.ModuleInfo)

pass1 :: [(GHC.Module, FullyCheckedModule, FilePath)] -> [Flag] -> Maybe String-> ErrMsgM ModuleMap2
pass1 modules flags package = worker modules (Map.empty) flags
  where
    worker :: [(GHC.Module, FullyCheckedModule, FilePath)] -> ModuleMap2 -> [Flag] -> ErrMsgM ModuleMap2
    worker [] moduleMap _ = return moduleMap
    worker ((mod, checked_mod, filename):rest_modules) moduleMap flags = do
 
      let (parsed_source, renamed_source, _, moduleInfo) = checked_mod
          (mb_doc_opts, _, _) = get_module_stuff parsed_source

      opts <- mk_doc_opts mb_doc_opts

      let (group, _, mb_exports, mbModDoc, haddockModInfo) = renamed_source
          entities = nubBy sameName (GHC.hs_docs group)
          exports = fmap (map unLoc) mb_exports 
 
          -- lots of names
          exportedNames = GHC.modInfoExports moduleInfo
          theseEntityNames = entityNames entities 
          subNames = allSubnamesInGroup group
          localNames = theseEntityNames ++ subNames
          -- guaranteed to be Just, since the module has been compiled from scratch 
          scopeNames = fromJust $ GHC.modInfoTopLevelScope moduleInfo 
      
          subMap = mk_sub_map_from_group group
        
      theseVisibleNames <- visibleNames mod moduleMap localNames scopeNames subMap exports opts

      let exportedDeclMap = mkDeclMap exportedNames group
          localDeclMap = mkDeclMap theseEntityNames group
          docMap = mkDocMap group

          ignoreAllExports = Flag_IgnoreAllExports `elem` flags
      
      exportItems <- mkExportItems moduleMap mod exportedNames
                                   exportedDeclMap localDeclMap subMap entities opts  
                                   exports ignoreAllExports docMap

     -- prune the export list to just those declarations that have
     -- documentation, if the 'prune' option is on.
      let prunedExportItems
	    | OptPrune `elem` opts = pruneExportItems exportItems
	    | otherwise = exportItems
 
          instances = GHC.modInfoInstances moduleInfo

          haddock_module = HM {
            hmod_mod                = mod,
            hmod_orig_filename      = filename,
            hmod_info               = haddockModInfo,
            hmod_doc                = mbModDoc,
            hmod_options            = opts,
            hmod_locals             = localNames,
            hmod_doc_map            = docMap,
            hmod_sub_map            = subMap,
            hmod_export_items       = prunedExportItems,
            hmod_exports            = exportedNames,
            hmod_visible_exports    = theseVisibleNames, 
            hmod_exported_decl_map  = exportedDeclMap,
            hmod_instances          = instances,
            hmod_package            = package
          }

          moduleMap' = Map.insert mod haddock_module moduleMap
      
      worker rest_modules moduleMap' flags 
      
      where 
        get_module_stuff source = 
          let GHC.HsModule _ _ _ _ _ mb_opts info mb_doc = unLoc source
          in (mb_opts, info, mb_doc)

        mk_doc_opts mb_opts = do
          opts <- case mb_opts of 
            Just opts -> processOptions opts
            Nothing -> return []
          let opts' = if Flag_HideModule (moduleString mod) `elem` flags 
                then OptHide : opts
                else opts      
          return opts'
 
sameName (GHC.DocEntity _) _ = False
sameName (GHC.DeclEntity _) (GHC.DocEntity _) = False
sameName (GHC.DeclEntity a) (GHC.DeclEntity b) = a == b

mkDocMap :: GHC.HsGroup GHC.Name -> Map GHC.Name (GHC.HsDoc GHC.Name)
mkDocMap group = Map.fromList $
  collectDocs (GHC.hs_docs group) ++ collectDocsFromClassMeths (getClasses group)
  where
    getClasses group = filter GHC.isClassDecl (map unLoc (GHC.hs_tyclds group))
    collectDocsFromClassMeths classes = concatMap (collectDocs . GHC.tcdDocs) classes
          
collectDocs :: [GHC.DocEntity GHC.Name] -> [(GHC.Name, GHC.HsDoc GHC.Name)]
collectDocs entities = collect Nothing GHC.DocEmpty entities

collect :: Maybe (GHC.DocEntity GHC.Name) -> GHC.HsDoc GHC.Name -> [GHC.DocEntity GHC.Name] -> [(GHC.Name, GHC.HsDoc GHC.Name)]
collect d doc_so_far [] =
   case d of
        Nothing -> []
        Just d0  -> finishedDoc d0 doc_so_far []

collect d doc_so_far (e:es) =
   case e of
      GHC.DocEntity (GHC.DocCommentNext str) ->
        case d of
           Nothing -> collect d (GHC.docAppend doc_so_far str) es
           Just d0 -> finishedDoc d0 doc_so_far (collect Nothing str es)

      GHC.DocEntity (GHC.DocCommentPrev str) -> collect d (GHC.docAppend doc_so_far str) es

      _other ->
        case d of
            Nothing -> collect (Just e) doc_so_far es
            Just d0 -> finishedDoc d0 doc_so_far
                           (collect (Just e) GHC.DocEmpty es)

finishedDoc :: GHC.DocEntity GHC.Name -> GHC.HsDoc GHC.Name -> [(GHC.Name, GHC.HsDoc GHC.Name)] -> [(GHC.Name, GHC.HsDoc GHC.Name)]
finishedDoc d GHC.DocEmpty rest = rest
finishedDoc (GHC.DeclEntity name) doc rest = (name, doc) : rest
finishedDoc _ _ rest = rest
        
allSubnamesInGroup :: GHC.HsGroup GHC.Name -> [GHC.Name]
allSubnamesInGroup group = 
  concat [ tail (map unLoc (GHC.tyClDeclNames tycld)) | L _ tycld <- GHC.hs_tyclds group ]

mk_sub_map_from_group :: GHC.HsGroup GHC.Name -> Map GHC.Name [GHC.Name]
mk_sub_map_from_group group =  
  Map.fromList [ (name, subs) | L _ tycld <- GHC.hs_tyclds group,
                 let name:subs = map unLoc (GHC.tyClDeclNames tycld) ]

mkDeclMap :: [GHC.Name] -> GHC.HsGroup GHC.Name -> Map GHC.Name (GHC.LHsDecl GHC.Name) 
mkDeclMap names group = Map.fromList [ (n,d)  | (n,Just d) <- maybeDecls ]
  where 
  maybeDecls = [ (name, getDeclFromGroup group name) | name <- names ]

entityNames :: [GHC.DocEntity GHC.Name] -> [GHC.Name]
entityNames entities = [ name | GHC.DeclEntity name <- entities ] 

getDeclFromGroup :: GHC.HsGroup GHC.Name -> GHC.Name -> Maybe (GHC.LHsDecl GHC.Name)
getDeclFromGroup group name = case catMaybes [getDeclFromVals  (GHC.hs_valds  group), 
                                              getDeclFromTyCls (GHC.hs_tyclds group),
                                              getDeclFromFors  (GHC.hs_fords  group)] of
  [decl] -> Just decl
  _ -> Nothing
  where 
    getDeclFromVals (GHC.ValBindsOut _ lsigs) = case matching of 
      [lsig] -> Just (L (getLoc lsig) (GHC.SigD (unLoc lsig)))
      _      -> Nothing
     where 
        matching = [ lsig | lsig <- lsigs, let Just n = GHC.sigName lsig, n == name ]
    getDeclFromVals _ = error "getDeclFromVals: illegal input"
     
    getDeclFromTyCls ltycls = case matching of 
      [ltycl] -> Just (L (getLoc ltycl) (GHC.TyClD (unLoc ltycl)))
      _       -> Nothing
      where
        matching = [ ltycl | ltycl <- ltycls, 
                     name `elem` map unLoc (GHC.tyClDeclNames (unLoc ltycl))]
 
    getDeclFromFors lfors = case matching of 
      [for] -> Just (L (getLoc for) (GHC.ForD (unLoc for)))
      _      -> Nothing
      where
        matching = [ for | for <- lfors, forName (unLoc for) == name ]
        forName (GHC.ForeignExport n _ _ _) = unLoc n
        forName (GHC.ForeignImport n _ _ _) = unLoc n
 
parseIfaceOption :: String -> (FilePath,FilePath)
parseIfaceOption s = 
  case break (==',') s of
	(fpath,',':file) -> (fpath,file)
	(file, _)        -> ("", file)
		
updateHTMLXRefs :: [FilePath] -> [[Interface]] -> IO ()
updateHTMLXRefs paths ifaces_s =
  writeIORef html_xrefs_ref (Map.fromList mapping)
 where
  mapping = [ (iface_module iface, fpath)
	    | (fpath, ifaces) <- zip paths ifaces_s,
	      iface <- ifaces
	    ]

getPrologue :: [Flag] -> IO (Maybe (GHC.HsDoc GHC.RdrName))
getPrologue flags
  = case [filename | Flag_Prologue filename <- flags ] of
	[] -> return Nothing 
	[filename] -> do
	   str <- readFile filename
	   case GHC.parseHaddockComment str of
		Left err -> dieMsg err
		Right doc -> return (Just doc)
	_otherwise -> dieMsg "multiple -p/--prologue options"

-- -----------------------------------------------------------------------------
-- Phase 2

renameModule :: Map GHC.Name GHC.Name -> HaddockModule -> ErrMsgM ([ExportItem2 DocName], Maybe (GHC.HsDoc DocName))
renameModule renamingEnv mod =

  -- first create the local env, where every name exported by this module
  -- is mapped to itself, and everything else comes from the global renaming
  -- env
  let localEnv = foldl fn renamingEnv (hmod_visible_exports mod)
        where fn env name = Map.insert name (nameSetMod name (hmod_mod mod)) env

  -- rename names in the exported declarations to point to things that
  -- are closer, or maybe even exported by, the current module.
      (renamedExportItems, missingNames1)
        = runRnFM localEnv (renameExportItems (hmod_export_items mod))

      (finalModuleDoc, missingNames2)
        = runRnFM localEnv (renameMaybeDoc (hmod_doc mod))

      missingNames = nub $ filter isExternalName (missingNames1 ++ missingNames2)
      strings = map (showSDoc . ppr) missingNames 
     
  in do
	-- report things that we couldn't link to.  Only do this
	-- for non-hidden modules.
   when (OptHide `notElem` hmod_options mod &&
	 not (null strings)) $
	  tell ["Warning: " ++ show (ppr (hmod_mod mod) defaultUserStyle) ++ 
		": could not find link destinations for:\n"++
		"   " ++ concat (map (' ':) strings)
		]

   --  trace (show (Map.toAscList import_env)) $ do

   return (renamedExportItems, finalModuleDoc)
 
-- -----------------------------------------------------------------------------
-- Build the list of items that will become the documentation, from the
-- export list.  At this point, the list of ExportItems is in terms of
-- original names.

mkExportItems
        :: ModuleMap2
	-> GHC.Module			-- this module
	-> [GHC.Name]			-- exported names (orig)
        -> Map GHC.Name (GHC.LHsDecl GHC.Name) -- maps exported names to declarations
	-> Map GHC.Name (GHC.LHsDecl GHC.Name) -- maps local names to declarations
	-> Map GHC.Name [GHC.Name]	-- sub-map for this module
	-> [GHC.DocEntity GHC.Name]	-- entities in the current module
	-> [DocOption]
	-> Maybe [GHC.IE GHC.Name]
	-> Bool				-- --ignore-all-exports flag
        -> Map GHC.Name (GHC.HsDoc GHC.Name)
	-> ErrMsgM [ExportItem2 GHC.Name]

mkExportItems mod_map this_mod exported_names exportedDeclMap localDeclMap sub_map entities
              opts maybe_exps ignore_all_exports docMap
  | isNothing maybe_exps || ignore_all_exports || OptIgnoreExports `elem` opts
    = everything_local_exported
  | Just specs <- maybe_exps = do 
      exps <- mapM lookupExport specs
      return (concat exps)
  where
    everything_local_exported =  -- everything exported
      return (fullContentsOfThisModule this_mod entities localDeclMap docMap)

    lookupExport (GHC.IEVar x)             = declWith x
    lookupExport (GHC.IEThingAbs t)        = declWith t
    lookupExport (GHC.IEThingAll t)        = declWith t
    lookupExport (GHC.IEThingWith t cs)    = declWith t
    lookupExport (GHC.IEModuleContents m)  = fullContentsOf m
    lookupExport (GHC.IEGroup lev doc)     = return [ ExportGroup2 lev "" doc ]
    lookupExport (GHC.IEDoc doc)           = return [ ExportDoc2 doc ] 
    lookupExport (GHC.IEDocNamed str)
	= do r <- findNamedDoc str entities
	     case r of
		Nothing -> return []
		Just found -> return [ ExportDoc2 found ]
 
    -- NOTE: I'm unsure about this. Currently only "External" names are considered.	
    declWith :: GHC.Name -> ErrMsgM [ ExportItem2 GHC.Name ]
    declWith t | not (isExternalName t) = return []
    declWith t
	| (Just decl, maybeDoc) <- findDecl t
        = return [ ExportDecl2 t (restrictTo subs (extractDecl t mdl decl)) maybeDoc [] ]
	| otherwise
	= return [ ExportNoDecl2 t t subs ]
	-- can't find the decl (it might be from another package), but let's
	-- list the entity anyway.  Later on, the renamer will change the
	-- orig name into the import name, so we get a proper link to
	-- the doc for this entity.
	where 
              mdl = nameModule t
	      subs = filter (`elem` exported_names) all_subs
              all_subs | mdl == this_mod = Map.findWithDefault [] t sub_map
		       | otherwise       = allSubsOfName mod_map t

    fullContentsOf m  
	| m == this_mod = return (fullContentsOfThisModule this_mod entities localDeclMap docMap)
	| otherwise = 
	   case Map.lookup m mod_map of
	     Just hmod
		| OptHide `elem` hmod_options hmod
			-> return (hmod_export_items hmod)
		| otherwise -> return [ ExportModule2 m ]
	     Nothing -> return [] -- already emitted a warning in exportedNames

    findDecl :: GHC.Name -> (Maybe (GHC.LHsDecl GHC.Name), Maybe (GHC.HsDoc GHC.Name))
    findDecl n | not (isExternalName n) = error "This shouldn't happen"
    findDecl n 
	| m == this_mod = (Map.lookup n exportedDeclMap, Map.lookup n docMap)
	| otherwise = 
	   case Map.lookup m mod_map of
		Just hmod -> (Map.lookup n (hmod_exported_decl_map hmod), 
                              Map.lookup n (hmod_doc_map hmod))
		Nothing -> (Nothing, Nothing)
      where
        m = nameModule n

fullContentsOfThisModule :: GHC.Module -> [GHC.DocEntity GHC.Name] -> Map GHC.Name (GHC.LHsDecl GHC.Name) ->
                            Map GHC.Name (GHC.HsDoc GHC.Name) -> [ExportItem2 GHC.Name]
fullContentsOfThisModule module_ entities declMap docMap = map mkExportItem entities
  where 
    mkExportItem (GHC.DocEntity (GHC.DocGroup lev doc)) = ExportGroup2 lev "" doc
    mkExportItem (GHC.DeclEntity name) = case Map.lookup name declMap of 
      Just decl -> let maybe_doc = Map.lookup name docMap in ExportDecl2 name decl maybe_doc []
      Nothing -> error "fullContentsOfThisModule: This shouldn't happen"

-- Sometimes the declaration we want to export is not the "main" declaration:
-- it might be an individual record selector or a class method.  In these
-- cases we have to extract the required declaration (and somehow cobble 
-- together a type signature for it...)
 
extractDecl :: GHC.Name -> GHC.Module -> GHC.LHsDecl GHC.Name -> GHC.LHsDecl GHC.Name
extractDecl name mdl decl
  | Just n <- GHC.getMainDeclBinder (unLoc decl), n == name = decl
  | otherwise  =  
    case unLoc decl of
      GHC.TyClD d | GHC.isClassDecl d -> 
        let matches = [ sig | sig <- GHC.tcdSigs d, GHC.sigName sig == Just name ] 
        in case matches of 
          [s0] -> let (n, tyvar_names) = name_and_tyvars d
                      L pos sig = extractClassDecl n mdl tyvar_names s0
                  in L pos (GHC.SigD sig)
          _ -> error "internal: extractDecl" 
      GHC.TyClD d | GHC.isDataDecl d -> 
        let (n, tyvar_names) = name_and_tyvars d
            L pos sig = extractRecSel name mdl n tyvar_names (GHC.tcdCons d)
        in L pos (GHC.SigD sig)
      _ -> error "internal: extractDecl"
  where
    name_and_tyvars d = (unLoc (GHC.tcdLName d), GHC.hsLTyVarLocNames (GHC.tcdTyVars d))

toTypeNoLoc :: Located GHC.Name -> GHC.LHsType GHC.Name
toTypeNoLoc lname = noLoc (GHC.HsTyVar (unLoc lname))

rmLoc :: Located a -> Located a
rmLoc a = noLoc (unLoc a)

-- originally expected unqualified 1:st name, now it doesn't
extractClassDecl :: GHC.Name -> GHC.Module -> [Located GHC.Name] -> GHC.LSig GHC.Name -> GHC.LSig GHC.Name
extractClassDecl c mdl tvs0 (L pos (GHC.TypeSig lname ltype)) = case ltype of
  L _ (GHC.HsForAllTy exp tvs (L _ preds) ty) -> 
    L pos (GHC.TypeSig lname (noLoc (GHC.HsForAllTy exp tvs (lctxt preds) ty)))
  _ -> L pos (GHC.TypeSig lname (noLoc (GHC.mkImplicitHsForAllTy (lctxt []) ltype)))
  where
    lctxt preds = noLoc (ctxt preds)
    ctxt preds = [noLoc (GHC.HsClassP c (map toTypeNoLoc tvs0))] ++ preds  

extractClassDecl _ _ _ d = error $ "extractClassDecl: unexpected decl"

extractRecSel :: GHC.Name -> GHC.Module -> GHC.Name -> [Located GHC.Name] -> [GHC.LConDecl GHC.Name]
              -> GHC.LSig GHC.Name
extractRecSel _ _ _ _ [] = error "extractRecSel: selector not found"

-- originally expected unqualified 3:rd name, now it doesn't
extractRecSel nm mdl t tvs (L _ con : rest) =
  case GHC.con_details con of
    GHC.RecCon fields | (GHC.HsRecField n ty _ : _) <- matching_fields fields -> 
      L (getLoc n) (GHC.TypeSig (noLoc nm) (noLoc (GHC.HsFunTy data_ty (GHC.getBangType ty))))
    _ -> extractRecSel nm mdl t tvs rest
 where 
  matching_fields flds = [ f | f@(GHC.HsRecField n _ _) <- flds, (unLoc n) == nm ]   
  data_ty = foldl (\x y -> noLoc (GHC.HsAppTy x y)) (noLoc (GHC.HsTyVar t)) (map toTypeNoLoc tvs)

-- -----------------------------------------------------------------------------
-- Pruning

pruneExportItems :: [ExportItem2 GHC.Name] -> [ExportItem2 GHC.Name]
pruneExportItems items = filter hasDoc items
  where hasDoc (ExportDecl2 _ _ d _) = isJust d
	hasDoc _ = True


-- -----------------------------------------------------------------------------
-- Gather a list of original names exported from this module

visibleNames :: GHC.Module 
             -> ModuleMap2  
             -> [GHC.Name] 
             -> [GHC.Name]
             -> Map GHC.Name [GHC.Name]
             -> Maybe [GHC.IE GHC.Name]
             -> [DocOption]
             -> ErrMsgM [GHC.Name]

visibleNames mdl modMap localNames scope subMap maybeExps opts
  -- if no export list, just return all local names 
  | Nothing <- maybeExps         = return localNames
  | OptIgnoreExports `elem` opts = return localNames
  | Just expspecs <- maybeExps = do
      visibleNames <- mapM extract expspecs
      return $ filter isNotPackageName (concat visibleNames)
 where
  isNotPackageName name = nameMod == mdl || isJust (Map.lookup nameMod modMap)
    where nameMod = nameModule name

  extract e = 
   case e of
    GHC.IEVar x -> return [x]
    GHC.IEThingAbs t -> return [t]
    GHC.IEThingAll t -> return (t : all_subs)
	 where
	      all_subs | nameModule t == mdl = Map.findWithDefault [] t subMap
		       | otherwise = allSubsOfName modMap t

    GHC.IEThingWith t cs -> return (t : cs)
	
    GHC.IEModuleContents m
	| m == mdl -> return localNames 
	| otherwise ->
	  case Map.lookup m modMap of
	    Just mod
		| OptHide `elem` hmod_options mod ->
		    return (filter (`elem` scope) (hmod_exports mod))
		| otherwise -> return []
	    Nothing
		-> tell ["Can not reexport a package module"] >> return []

    _ -> return []

-- for a given entity, find all the names it "owns" (ie. all the
-- constructors and field names of a tycon, or all the methods of a
-- class).
allSubsOfName :: ModuleMap2 -> GHC.Name -> [GHC.Name]
allSubsOfName mod_map name 
  | isExternalName name =
    case Map.lookup (nameModule name) mod_map of
      Just hmod -> Map.findWithDefault [] name (hmod_sub_map hmod)
      Nothing   -> []
  | otherwise =  error $ "Main.allSubsOfName: unexpected unqual'd name"

-- | Build a mapping which for each original name, points to the "best"
-- place to link to in the documentation.  For the definition of
-- "best", we use "the module nearest the bottom of the dependency
-- graph which exports this name", not including hidden modules.  When
-- there are multiple choices, we pick a random one.
-- 
-- The interfaces are passed in in topologically sorted order, but we start
-- by reversing the list so we can do a foldl.
-- 

buildGlobalDocEnv :: [HaddockModule] -> Map GHC.Name GHC.Name
buildGlobalDocEnv modules
 = foldl upd Map.empty (reverse modules)
 where
  upd old_env mod
     | OptHide `elem` hmod_options mod
     = old_env
     | OptNotHome `elem` hmod_options mod
     = foldl' keep_old old_env exported_names
     | otherwise
     = foldl' keep_new old_env exported_names
     where
	exported_names = hmod_visible_exports mod
        modName = hmod_mod mod

	keep_old env n = Map.insertWith (\new old -> old) 
			 n (nameSetMod n modName) env
	keep_new env n = Map.insert n (nameSetMod n modName) env 

nameSetMod n newMod = mkExternalName (nameUnique n) newMod (nameOccName n) Nothing (nameSrcLoc n)

-- -----------------------------------------------------------------------------
-- Named documentation

findNamedDoc :: String -> [GHC.DocEntity GHC.Name] -> ErrMsgM (Maybe (GHC.HsDoc GHC.Name))
findNamedDoc name entities = search entities 
	where search [] = do
		tell ["Cannot find documentation for: $" ++ name]
		return Nothing
	      search ((GHC.DocEntity (GHC.DocCommentNamed name' doc)):rest) 
			| name == name' = return (Just doc)
		   	| otherwise = search rest
	      search (_other_decl : rest) = search rest

-- -----------------------------------------------------------------------------
-- Haddock options embedded in the source file

processOptions_ str = let (opts, msg) = runWriter (processOptions str) 
                      in print msg >> return opts 

processOptions :: String -> ErrMsgM [DocOption]
processOptions str = do
  case break (== ',') str of
    (this, ',':rest) -> do
	opt <- parseOption this
	opts <- processOptions rest
	return (maybeToList opt ++ opts)
    (this, _)
	| all isSpace this -> return []
	| otherwise -> do opt <- parseOption this; return (maybeToList opt)

parseOption :: String -> ErrMsgM (Maybe DocOption)
parseOption "hide" = return (Just OptHide)
parseOption "prune" = return (Just OptPrune)
parseOption "ignore-exports" = return (Just OptIgnoreExports)
parseOption "not-home" = return (Just OptNotHome)
parseOption other = do tell ["Unrecognised option: " ++ other]; return Nothing

-- simplified type for sorting types, ignoring qualification (not visible
-- in Haddock output) and unifying special tycons with normal ones.
data SimpleType = SimpleType GHC.Name [SimpleType] deriving (Eq,Ord)

attachInstances :: [HaddockModule] -> [HaddockModule]
attachInstances modules = map attach modules
  where
    instMap = fmap (map toHsInstHead . sortImage instHead) $ collectInstances modules
    attach mod = mod { hmod_export_items = newItems }
      where
        newItems = map attachExport (hmod_export_items mod)

        attachExport (ExportDecl2 n decl doc _) =
          ExportDecl2 n decl doc (case Map.lookup n instMap of
                                   Nothing -> []
                                   Just instheads -> instheads)
        attachExport otherExport = otherExport

collectInstances
   :: [HaddockModule]
   -> Map GHC.Name [([GHC.TyVar], [GHC.PredType], Class, [Type])]  -- maps class/type names to instances

collectInstances modules
  = Map.fromListWith (flip (++)) tyInstPairs `Map.union`
    Map.fromListWith (flip (++)) classInstPairs
  where
    allInstances = concat (map hmod_instances modules)
    classInstPairs = [ (is_cls inst, [instanceHead inst]) | 
                       inst <- allInstances ]
    tyInstPairs = [ (tycon, [instanceHead inst]) | inst <- allInstances, 
                    Just tycon <- nub (is_tcs inst) ]

instHead :: ([GHC.TyVar], [GHC.PredType], Class, [Type]) -> ([Int], GHC.Name, [SimpleType])
instHead (_, _, cls, args)
  = (map argCount args, className cls, map simplify args)
  where
    argCount (AppTy t _) = argCount t + 1
    argCount (TyConApp _ ts) = length ts
    argCount (FunTy _ _ ) = 2
    argCount (ForAllTy _ t) = argCount t
    argCount (NoteTy _ t) = argCount t
    argCount _ = 0

    simplify (ForAllTy _ t) = simplify t
    simplify (FunTy t1 t2) = 
      SimpleType funTyConName [simplify t1, simplify t2]
    simplify (AppTy t1 t2) = SimpleType s (args ++ [simplify t2])
      where (SimpleType s args) = simplify t1
    simplify (TyVarTy v) = SimpleType (tyVarName v) []
    simplify (TyConApp tc ts) = SimpleType (tyConName tc) (map simplify ts)
    simplify (NoteTy _ t) = simplify t
    simplify _ = error "simplify"

-- sortImage f = sortBy (\x y -> compare (f x) (f y))
sortImage :: Ord b => (a -> b) -> [a] -> [a]
sortImage f xs = map snd $ sortBy cmp_fst [(f x, x) | x <- xs]
 where cmp_fst (x,_) (y,_) = compare x y

funTyConName = mkWiredInName gHC_PRIM
                        (mkOccNameFS tcName FSLIT("(->)"))
                        funTyConKey
                        Nothing                 -- No parent object
                        (ATyCon funTyCon)       -- Relevant TyCon
                        BuiltInSyntax

toHsInstHead :: ([GHC.TyVar], [GHC.PredType], Class, [Type]) -> InstHead2 GHC.Name
toHsInstHead (_, preds, cls, ts) = (map toHsPred preds, className cls, map toHsType ts) 

toHsPred :: PredType -> GHC.HsPred GHC.Name 
toHsPred (ClassP cls ts) = GHC.HsClassP (className cls) (map toLHsType ts)
toHsPred (IParam n t) = GHC.HsIParam n (toLHsType t)

toLHsType = noLoc . toHsType
 
toHsType :: Type -> GHC.HsType GHC.Name
toHsType t = case t of 
  TyVarTy v -> GHC.HsTyVar (tyVarName v) 
  AppTy a b -> GHC.HsAppTy (toLHsType a) (toLHsType b)
  TyConApp tc ts -> case ts of 
    [] -> GHC.HsTyVar (tyConName tc)
    _  -> GHC.HsAppTy (tycon tc) (args ts)
  FunTy a b -> GHC.HsFunTy (toLHsType a) (toLHsType b) 
  ForAllTy v t -> cvForAll [v] t 
  PredTy p -> GHC.HsPredTy (toHsPred p) 
  NoteTy _ t -> toHsType t
  where

    tycon tc = noLoc (GHC.HsTyVar (tyConName tc))
    args ts = foldl1 (\a b -> noLoc $ GHC.HsAppTy a b) (map toLHsType ts)
    
    cvForAll vs (ForAllTy v t) = cvForAll (v:vs) t
    cvForAll vs t = GHC.mkExplicitHsForAllTy (tyvarbinders vs) (noLoc []) (toLHsType t)
    tyvarbinders vs = map (noLoc . GHC.UserTyVar . tyVarName) vs

-- -----------------------------------------------------------------------------
-- A monad which collects error messages

type ErrMsg = String
type ErrMsgM a = Writer [ErrMsg] a
