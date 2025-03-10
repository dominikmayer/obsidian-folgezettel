module Main exposing (..)

import Browser
import Dict exposing (Dict)
import Html exposing (Html, div)
import Html.Attributes
import Html.Events exposing (onClick)
import Html.Events.Extra.Mouse as Mouse
import Html.Lazy exposing (lazy)
import Json.Decode as Decode
import Json.Encode as Encode
import NoteId
import Ports exposing (..)
import Task
import VirtualList
import VirtualList.Config



-- CONSTANTS


uniqueIdRetries : Int
uniqueIdRetries =
    50



-- MAIN


main : Program Encode.Value Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }



-- MODEL


type Display
    = TOC
    | Notes


type alias Model =
    { notes : List NoteWithSplit
    , currentFile : Maybe String
    , settings : Settings
    , scrollToNewlyOpenedNote : Bool
    , display : Display
    , virtualList : VirtualList.Model
    }


defaultModel : Model
defaultModel =
    let
        config =
            VirtualList.Config.default
                |> VirtualList.Config.setBuffer 10
    in
    { notes = []
    , currentFile = Nothing
    , settings = defaultSettings
    , scrollToNewlyOpenedNote = True
    , display = Notes
    , virtualList = VirtualList.initWithConfig config
    }


type alias NoteMeta =
    { title : String
    , tocTitle : Maybe String
    , id : Maybe String
    , filePath : String
    }


type alias NoteWithSplit =
    { note : NoteMeta
    , splitLevel : Maybe Int
    }


type alias Settings =
    { includeFolders : List String
    , excludeFolders : List String
    , showNotesWithoutId : Bool
    , idField : String
    , tocField : String
    , tocLevel : Maybe Int
    , splitLevel : Int
    , indentation : Bool
    }


defaultSettings : Settings
defaultSettings =
    { includeFolders = []
    , excludeFolders = []
    , showNotesWithoutId = True
    , idField = "id"
    , tocField = "toc"
    , tocLevel = Just 1
    , splitLevel = 0
    , indentation = False
    }


init : Encode.Value -> ( Model, Cmd Msg )
init flags =
    let
        model =
            { defaultModel
                | settings = decodeSettings defaultSettings flags
                , currentFile = decodeActiveFile flags
            }
    in
    -- Won't find the note yet but initiate the future scroll
    scrollToCurrentNote model



-- ( model, Cmd.none )


decodeSettings : Settings -> Decode.Value -> Settings
decodeSettings settings newSettings =
    case Decode.decodeValue (Decode.field "settings" partialSettingsDecoder) newSettings of
        Ok decoded ->
            decoded settings

        Err _ ->
            settings


decodeActiveFile : Encode.Value -> Maybe String
decodeActiveFile flags =
    case Decode.decodeValue (Decode.field "activeFile" Decode.string) flags of
        Ok path ->
            Just path

        Err _ ->
            Nothing



-- UPDATE


type Msg
    = ContextMenuTriggered Mouse.Event String
    | DisplayChanged Bool
    | FileOpened (Maybe String)
    | FileRenamed ( String, String )
    | NewIdRequestedForNoteFromNote ( String, String, Bool )
    | NoteClicked String
    | NoteCreationRequested ( String, Bool )
    | NotesProvided ( List NoteMeta, List String )
    | ScrollRequested String
    | SettingsChanged Ports.Settings
    | VirtualListMsg VirtualList.Msg


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        ContextMenuTriggered event path ->
            let
                ( x, y ) =
                    event.clientPos
            in
            ( model, Ports.openContextMenu ( x, y, path ) )

        DisplayChanged tocShown ->
            handleDisplayChange model tocShown

        FileOpened filePath ->
            fileOpened model filePath

        FileRenamed paths ->
            handleFileRename model paths

        NewIdRequestedForNoteFromNote ( for, from, subsequence ) ->
            let
                cmd =
                    getNewIdFromNote model.notes from subsequence
                        |> Maybe.map (\id -> Ports.provideNewIdForNote ( id, for ))
                        |> Maybe.withDefault Cmd.none
            in
            ( model, cmd )

        NoteCreationRequested ( filePath, child ) ->
            createNote model filePath child

        NoteClicked filePath ->
            handleNoteClick model filePath

        NotesProvided ( notes, changedNotes ) ->
            updateNotes model notes changedNotes

        ScrollRequested path ->
            scrollToNote model path

        SettingsChanged settings ->
            handleSettingsChange model settings

        VirtualListMsg virtualListMsg ->
            mapVirtualListResult (VirtualList.update virtualListMsg model.virtualList) model


handleDisplayChange : Model -> Bool -> ( Model, Cmd Msg )
handleDisplayChange model tocShown =
    let
        newDisplay =
            if tocShown then
                TOC

            else
                Notes
    in
    reloadNotesAndScroll model newDisplay


reloadNotesAndScroll : Model -> Display -> ( Model, Cmd Msg )
reloadNotesAndScroll model newDisplay =
    let
        ( newModelPre, displayCmd ) =
            updateDisplay model newDisplay

        ( newModel, scrollCmd ) =
            scrollToCurrentNote newModelPre
    in
    ( newModel, Cmd.batch [ displayCmd, scrollCmd ] )


handleNoteClick : Model -> String -> ( Model, Cmd Msg )
handleNoteClick model filePath =
    let
        ( newModel, updateCmd ) =
            if model.display == TOC then
                updateDisplay model Notes

            else
                ( model, Cmd.none )

        fileIsAlreadyOpen =
            Maybe.map ((==) filePath) model.currentFile |> Maybe.withDefault False

        fileCmd =
            if fileIsAlreadyOpen then
                Task.perform (\_ -> ScrollRequested filePath) (Task.succeed ())

            else
                Ports.openFile filePath

        cmd =
            Cmd.batch [ fileCmd, updateCmd ]
    in
    ( { newModel | scrollToNewlyOpenedNote = model.display == TOC }, cmd )


updateDisplay : Model -> Display -> ( Model, Cmd Msg )
updateDisplay model newDisplay =
    let
        newModel =
            { model | display = newDisplay }

        ( updatedModel, updateCmd ) =
            updateVirtualList newModel

        cmd =
            Cmd.batch
                [ updateCmd
                , Ports.toggleTOCButton (newDisplay == TOC)
                ]
    in
    ( updatedModel
    , cmd
    )


handleSettingsChange : Model -> Ports.Settings -> ( Model, Cmd Msg )
handleSettingsChange model portSettings =
    let
        transformedSettings =
            { includeFolders = portSettings.includeFolders
            , excludeFolders = portSettings.excludeFolders
            , showNotesWithoutId = portSettings.showNotesWithoutId
            , idField = portSettings.idField
            , tocField = portSettings.tocField
            , tocLevel =
                if portSettings.autoToc then
                    Just portSettings.tocLevel

                else
                    Nothing
            , splitLevel = portSettings.splitLevel
            , indentation = portSettings.indentation
            }

        ( newModel, cmd ) =
            updateVirtualList model
    in
    ( { newModel
        | settings = transformedSettings
      }
    , cmd
    )


updateVirtualList : Model -> ( Model, Cmd Msg )
updateVirtualList model =
    let
        ids =
            model.notes
                |> List.map (.note >> .filePath)
    in
    updateVirtualListHelper model ids


updateVirtualListHelper : Model -> List String -> ( Model, Cmd Msg )
updateVirtualListHelper model idsToRemeasure =
    let
        filteredNotes =
            filterNotes model.display model.settings.tocLevel model.notes

        ids =
            filteredNotes
                |> List.map (.note >> .filePath)

        ( newVirtualList, virtualListCmd ) =
            VirtualList.setItemsAndRemeasure model.virtualList { newIds = ids, idsToRemeasure = idsToRemeasure }
    in
    ( { model
        | virtualList = newVirtualList
      }
    , Cmd.map VirtualListMsg virtualListCmd
    )


mapVirtualListResult : ( VirtualList.Model, Cmd VirtualList.Msg ) -> Model -> ( Model, Cmd Msg )
mapVirtualListResult ( virtualListModel, virtualListCmd ) model =
    ( { model | virtualList = virtualListModel }, Cmd.map VirtualListMsg virtualListCmd )


createNote : Model -> String -> Bool -> ( Model, Cmd Msg )
createNote model path child =
    let
        newPath =
            getPathWithoutFileName path ++ "/Untitled.md"

        fileContent =
            getNewIdFromNote model.notes path child
                |> Maybe.map (createNoteContent model.settings.idField)
                |> Maybe.withDefault ""
    in
    ( model, Ports.createNote ( newPath, fileContent ) )


getNewIdFromNote : List NoteWithSplit -> String -> Bool -> Maybe String
getNewIdFromNote notes path child =
    let
        id =
            getNoteByPath path notes
                |> Maybe.andThen (\noteWithSplit -> noteWithSplit.note.id)
    in
    Maybe.map (getId child) id
        |> Maybe.andThen (getUniqueId notes)


getId : Bool -> String -> String
getId child id =
    if child then
        NoteId.getNewIdInSubsequence id

    else
        NoteId.getNewIdInSequence id


getUniqueId : List NoteWithSplit -> String -> Maybe String
getUniqueId notes id =
    -- Prevents infinite loops
    generateUniqueId notes id uniqueIdRetries


generateUniqueId : List NoteWithSplit -> String -> Int -> Maybe String
generateUniqueId notes id remainingAttempts =
    if remainingAttempts <= 0 then
        Nothing

    else if isNoteIdTaken notes id then
        generateUniqueId notes (NoteId.getNewIdInSequence id) (remainingAttempts - 1)

    else
        Just id


isNoteIdTaken : List NoteWithSplit -> String -> Bool
isNoteIdTaken notes noteId =
    List.any (\noteWithSplit -> noteWithSplit.note.id == Just noteId) notes


createNoteContent : String -> String -> String
createNoteContent idNameFromSettings id =
    let
        idName =
            if String.isEmpty idNameFromSettings then
                "id"

            else
                idNameFromSettings
    in
    "---\n" ++ idName ++ ": " ++ id ++ "\n---"


getPathWithoutFileName : String -> String
getPathWithoutFileName filePath =
    let
        components =
            String.split "/" filePath

        withoutFileName =
            List.take (List.length components - 1) components
    in
    String.join "/" withoutFileName


updateNotes : Model -> List NoteMeta -> List String -> ( Model, Cmd Msg )
updateNotes model newNotes changedNotes =
    let
        annotatedNotes =
            annotateNotes (sortNotes newNotes)

        affectedIds =
            if List.isEmpty model.notes then
                -- On initial load, all new notes need to be measured
                List.map (.note >> .filePath) annotatedNotes

            else
                let
                    changedSplitIds =
                        findNotesWithSplitChanges { oldNotes = model.notes, newNotes = annotatedNotes }
                in
                List.append changedSplitIds changedNotes

        modelWithSortedNotes =
            { model | notes = annotatedNotes }

        ( modelWithUpdatedVirtualList, cmd ) =
            updateVirtualListHelper modelWithSortedNotes affectedIds
    in
    ( modelWithUpdatedVirtualList, cmd )


findNotesWithSplitChanges : { oldNotes : List NoteWithSplit, newNotes : List NoteWithSplit } -> List String
findNotesWithSplitChanges { oldNotes, newNotes } =
    newNotes
        |> List.filter
            (splitHasChanged
                { oldNoteMap = createSplitMap oldNotes
                , newNoteMap = createSplitMap newNotes
                }
            )
        |> List.map (.note >> .filePath)


createSplitMap : List NoteWithSplit -> Dict String (Maybe Int)
createSplitMap notes =
    notes
        |> List.map (\noteWithSplit -> ( noteWithSplit.note.filePath, noteWithSplit.splitLevel ))
        |> Dict.fromList


splitHasChanged : { oldNoteMap : Dict String (Maybe Int), newNoteMap : Dict String (Maybe Int) } -> NoteWithSplit -> Bool
splitHasChanged { oldNoteMap, newNoteMap } noteWithSplit =
    let
        filePath =
            noteWithSplit.note.filePath

        oldSplit =
            Dict.get filePath oldNoteMap

        newSplit =
            Dict.get filePath newNoteMap
    in
    oldSplit /= newSplit


filterNotes : Display -> Maybe Int -> List NoteWithSplit -> List NoteWithSplit
filterNotes display maybeTocLevel notes =
    case display of
        TOC ->
            List.filter
                (\noteWithSplit ->
                    let
                        hasTocField =
                            noteWithSplit.note.tocTitle /= Nothing

                        noteLevel =
                            Maybe.withDefault 0 (noteWithSplit.note.id |> Maybe.map NoteId.level)
                    in
                    case maybeTocLevel of
                        Just tocLevel ->
                            hasTocField || (0 < noteLevel && noteLevel <= tocLevel)

                        Nothing ->
                            hasTocField
                )
                notes

        Notes ->
            notes


sortNotes : List NoteMeta -> List NoteMeta
sortNotes notes =
    List.sortWith
        (\a b ->
            case ( a.id, b.id ) of
                ( Nothing, Nothing ) ->
                    compare (String.toLower a.title) (String.toLower b.title)

                ( Nothing, Just _ ) ->
                    GT

                ( Just _, Nothing ) ->
                    LT

                ( Just idA, Just idB ) ->
                    NoteId.compareId idA idB
        )
        notes


handleFileRename : Model -> ( String, String ) -> ( Model, Cmd Msg )
handleFileRename model ( oldPath, newPath ) =
    let
        updatedCurrentFile =
            updateCurrentFile model.currentFile oldPath newPath

        ( newModel, cmd ) =
            if model.currentFile == Just oldPath then
                scrollToNote model newPath

            else
                ( model, Cmd.none )
    in
    ( { newModel | currentFile = updatedCurrentFile }, cmd )


updateCurrentFile : Maybe String -> String -> String -> Maybe String
updateCurrentFile current oldPath newPath =
    if current == Just oldPath then
        Just newPath

    else
        current


getNoteByPath : String -> List NoteWithSplit -> Maybe NoteWithSplit
getNoteByPath path notes =
    notes
        |> List.filter (\noteWithSplit -> noteWithSplit.note.filePath == path)
        |> List.head


fileOpened : Model -> Maybe String -> ( Model, Cmd Msg )
fileOpened model filePath =
    case filePath of
        Just path ->
            let
                ( updatedModel, scrollCmd ) =
                    scrollToExternallyOpenedNote model path
            in
            ( { updatedModel | currentFile = Just path }, scrollCmd )

        Nothing ->
            ( model, Cmd.none )


scrollToExternallyOpenedNote : Model -> String -> ( Model, Cmd Msg )
scrollToExternallyOpenedNote model path =
    if model.scrollToNewlyOpenedNote then
        scrollToNote model path

    else
        ( { model | scrollToNewlyOpenedNote = True }, Cmd.none )


scrollToNote : Model -> String -> ( Model, Cmd Msg )
scrollToNote model path =
    let
        ( newVirtualList, virtualListCmd ) =
            VirtualList.scrollToItem model.virtualList path VirtualList.Center
    in
    ( { model | virtualList = newVirtualList }
    , Cmd.map VirtualListMsg virtualListCmd
    )


scrollToCurrentNote : Model -> ( Model, Cmd Msg )
scrollToCurrentNote model =
    case model.currentFile of
        Just path ->
            scrollToNote model path

        Nothing ->
            ( model, Cmd.none )



-- VIEW


annotateNotes : List NoteMeta -> List NoteWithSplit
annotateNotes notes =
    let
        annotate xs =
            case xs of
                [] ->
                    []

                first :: rest ->
                    let
                        initialSplit =
                            case first.id of
                                Nothing ->
                                    Just 1

                                Just _ ->
                                    Nothing
                    in
                    { note = first, splitLevel = initialSplit }
                        :: annotateRest first rest

        annotateRest prev xs =
            case xs of
                [] ->
                    []

                current :: rest ->
                    let
                        computedSplit =
                            case ( prev.id, current.id ) of
                                ( Just prevId, Just currId ) ->
                                    NoteId.splitLevel prevId currId

                                ( Just _, Nothing ) ->
                                    Just 1

                                ( Nothing, Just _ ) ->
                                    Just 1

                                ( Nothing, Nothing ) ->
                                    -- If two consecutive notes lack an id, assume they belong to the same block.
                                    Nothing
                    in
                    { note = current, splitLevel = computedSplit }
                        :: annotateRest current rest
    in
    annotate notes


view : Model -> Html Msg
view model =
    VirtualList.view (lazy (renderRow model)) model.virtualList VirtualListMsg


renderRow : Model -> String -> Html Msg
renderRow model filePath =
    case getNoteByPath filePath model.notes of
        Just noteWithSplit ->
            renderNote model noteWithSplit.note noteWithSplit.splitLevel

        Nothing ->
            div [] []


renderNote : Model -> NoteMeta -> Maybe Int -> Html Msg
renderNote model note maybeSplit =
    let
        marginTopStyle =
            if model.display == TOC then
                []

            else
                case maybeSplit of
                    Just splitLevel ->
                        if 0 < splitLevel && splitLevel <= model.settings.splitLevel then
                            adaptedMarginTopStyle model.settings.splitLevel splitLevel

                        else
                            []

                    Nothing ->
                        []

        level =
            note.id
                |> Maybe.map NoteId.level
                |> Maybe.withDefault 0
                |> toFloat

        marginLeftStyle =
            if model.settings.indentation then
                [ marginLeft level ]

            else
                []

        title =
            if model.display == TOC then
                Maybe.withDefault note.title note.tocTitle

            else
                note.title
    in
    div
        ([ Html.Attributes.classList
            [ ( "tree-item-self", True )
            , ( "is-clickable", True )
            , ( "is-active", Just note.filePath == model.currentFile )
            ]
         , Html.Attributes.attribute "data-path" note.filePath
         , onClick (NoteClicked note.filePath)
         , Mouse.onContextMenu (\event -> ContextMenuTriggered event note.filePath)
         ]
            ++ marginTopStyle
        )
        [ div
            (Html.Attributes.class "tree-item-inner" :: marginLeftStyle)
            (case note.id of
                Just id ->
                    [ Html.span [ Html.Attributes.class "note-id" ] [ Html.text (id ++ ": ") ]
                    , Html.text title
                    ]

                Nothing ->
                    [ Html.text title ]
            )
        ]


adaptedMarginTopStyle : Int -> Int -> List (Html.Attribute msg)
adaptedMarginTopStyle splitLevelSetting level =
    let
        availableSizes =
            [ "--size-4-8"
            , "--size-4-9"
            , "--size-4-12"
            , "--size-4-16"
            , "--size-4-18"
            ]

        sizeMap : Dict Int String
        sizeMap =
            List.indexedMap (\i size -> ( splitLevelSetting - i, size )) availableSizes
                |> Dict.fromList

        marginSize =
            Dict.get level sizeMap
                |> Maybe.withDefault "--size-4-18"
    in
    [ Html.Attributes.style "margin-top" ("var(" ++ marginSize ++ ")") ]


marginLeft : Float -> Html.Attribute msg
marginLeft level =
    Html.Attributes.style "margin-left" ("calc(var(--size-2-3) * " ++ String.fromFloat level ++ ")")


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.batch
        [ Ports.receiveNotes NotesProvided
        , Ports.receiveCreateNote NoteCreationRequested
        , Ports.receiveDisplayIsToc DisplayChanged
        , Ports.receiveFileOpen FileOpened
        , Ports.receiveFileRenamed FileRenamed
        , Ports.receiveGetNewIdForNoteFromNote NewIdRequestedForNoteFromNote
        , Ports.receiveSettings SettingsChanged
        ]


tocLevelDecoder : Decode.Decoder (Maybe Int)
tocLevelDecoder =
    Decode.map2
        (\autoToc tocLevel ->
            if autoToc then
                tocLevel

            else
                Nothing
        )
        (Decode.field "autoToc" Decode.bool |> Decode.maybe |> Decode.map (Maybe.withDefault True))
        (Decode.field "tocLevel" Decode.int |> Decode.maybe)


partialSettingsDecoder : Decode.Decoder (Settings -> Settings)
partialSettingsDecoder =
    Decode.map8
        (\includeFolders excludeFolders showNotesWithoutId idField tocField newTocLevel splitLevel indentation settings ->
            { settings
                | includeFolders = includeFolders |> Maybe.withDefault settings.includeFolders
                , excludeFolders = excludeFolders |> Maybe.withDefault settings.excludeFolders
                , showNotesWithoutId = showNotesWithoutId |> Maybe.withDefault settings.showNotesWithoutId
                , idField = idField |> Maybe.withDefault settings.idField
                , tocField = tocField |> Maybe.withDefault settings.tocField
                , tocLevel = newTocLevel
                , splitLevel = splitLevel |> Maybe.withDefault settings.splitLevel
                , indentation = indentation |> Maybe.withDefault settings.indentation
            }
        )
        (Decode.field "includeFolders" (Decode.list Decode.string) |> Decode.maybe)
        (Decode.field "excludeFolders" (Decode.list Decode.string) |> Decode.maybe)
        (Decode.field "showNotesWithoutId" Decode.bool |> Decode.maybe)
        (Decode.field "idField" Decode.string |> Decode.maybe)
        (Decode.field "tocField" Decode.string |> Decode.maybe)
        tocLevelDecoder
        (Decode.field "splitLevel" Decode.int |> Decode.maybe)
        (Decode.field "indentation" Decode.bool |> Decode.maybe)
