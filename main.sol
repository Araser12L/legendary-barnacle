// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title LegendaryBarnacle
 * @notice On-chain art generator platform: artists mint works, galleries curate and earn commission. Traits and metadata hashes stored on-chain.
 * @dev All config set at deploy; curator and treasury immutable. ReentrancyGuard and explicit checks for mainnet safety.
 */

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/ReentrancyGuard.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/access/Ownable.sol";

contract LegendaryBarnacle is ReentrancyGuard, Ownable {

    event ArtistRegistered(address indexed artist, bytes32 handleHash, uint256 artistId, uint256 atBlock);
    event ArtworkMinted(
        uint256 indexed artworkId,
        address indexed artist,
        uint256 galleryId,
        bytes32 metadataHash,
        uint256 mintPriceWei,
        uint256 atBlock
    );
    event GalleryCreated(uint256 indexed galleryId, address indexed curator, bytes32 nameHash, uint256 commissionBps, uint256 atBlock);
    event ArtworkListedInGallery(uint256 indexed artworkId, uint256 indexed galleryId, uint256 listPriceWei, uint256 atBlock);
    event ArtworkDelisted(uint256 indexed artworkId, uint256 indexed galleryId, uint256 atBlock);
    event ArtworkPurchased(
        uint256 indexed artworkId,
        address indexed buyer,
        address indexed previousOwner,
        uint256 priceWei,
        uint256 artistShare,
        uint256 galleryShare,
        uint256 atBlock
    );
    event ProceedsWithdrawn(address indexed recipient, uint256 amountWei, uint8 kind, uint256 atBlock);
    event PlatformPauseToggled(bool paused);
    event CuratorUpdated(uint256 indexed galleryId, address indexed newCurator, uint256 atBlock);
    event TraitRecorded(uint256 indexed artworkId, bytes32 traitKey, bytes32 traitValue, uint256 atBlock);

    error LB_ZeroAddress();
    error LB_ZeroAmount();
    error LB_PlatformPaused();
    error LB_ArtistNotFound();
    error LB_ArtistAlreadyRegistered();
    error LB_ArtworkNotFound();
    error LB_GalleryNotFound();
    error LB_NotCurator();
    error LB_NotArtist();
    error LB_InvalidCommissionBps();
    error LB_InvalidRoyaltyBps();
    error LB_TransferFailed();
    error LB_AlreadyListed();
    error LB_NotListed();
    error LB_InsufficientPayment();
    error LB_NotOwner();
    error LB_MaxTraitsExceeded();
    error LB_MaxGalleriesExceeded();
    error LB_MaxArtworksExceeded();
    error LB_Reentrancy();

    uint256 public constant BPS_DENOM = 10000;
    uint256 public constant MAX_COMMISSION_BPS = 2500;
    uint256 public constant MAX_ROYALTY_BPS = 2000;
    uint256 public constant MAX_TRAITS_PER_ARTWORK = 16;
    uint256 public constant MAX_GALLERIES = 100;
    uint256 public constant MAX_ARTWORKS = 10000;
    uint256 public constant LEGENDARY_SEED = 0x1E4F7A2C5D8B0E3F6A9C2D5E8B1F4A7C0D3E6B9F2;

    address public immutable platformTreasury;
    address public immutable genesisCurator;
    uint256 public immutable deployedAtBlock;
    bytes32 public immutable chainSalt;

    uint256 public artistCounter;
    uint256 public artworkCounter;
    uint256 public galleryCounter;
    bool public platformPaused;

    struct ArtistProfile {
        address artist;
        bytes32 handleHash;
        uint256 totalMints;
        uint256 totalEarningsWei;
        uint256 registeredAtBlock;
        bool active;
    }

    struct ArtworkRecord {
        address artist;
        uint256 galleryId;
        bytes32 metadataHash;
        uint256 mintPriceWei;
        uint256 royaltyBps;
        uint256 mintedAtBlock;
        address currentOwner;
        uint256 listPriceWei;
        uint256 listedAtGalleryId;
        bool listed;
    }

    struct GalleryRecord {
        address curator;
        bytes32 nameHash;
        uint256 commissionBps;
        uint256 totalEarningsWei;
        uint256 createdAtBlock;
        bool active;
    }

    struct TraitPair {
        bytes32 key;
        bytes32 value;
    }

    mapping(uint256 => ArtistProfile) public artistProfiles;
    mapping(address => uint256) public artistIdByAddress;
    mapping(uint256 => ArtworkRecord) public artworkRecords;
    mapping(uint256 => GalleryRecord) public galleryRecords;
    mapping(uint256 => TraitPair[]) public traitsByArtwork;
    mapping(uint256 => uint256[]) public artworkIdsByGallery;
    mapping(uint256 => uint256[]) public artworkIdsByArtist;
    mapping(address => uint256) public pendingArtistProceeds;
    mapping(uint256 => mapping(uint256 => uint256)) public pendingGalleryProceedsByArtwork;
    mapping(uint256 => uint256) public pendingGalleryProceeds;
    mapping(address => uint256[]) public ownedArtworkIds;

    uint256[] private _allArtistIds;
    uint256[] private _allGalleryIds;
    uint256[] private _allArtworkIds;

    modifier whenNotPaused() {
        if (platformPaused) revert LB_PlatformPaused();
        _;
    }

    constructor() {
        platformTreasury = address(0xF1a3C5e7B9d2F4a6C8e0B2d4F6a8C0e2A4c6E8f1);
        genesisCurator = address(0xB4d6F8a0C2e4A6c8E0b2D4f6A8c0E2a4C6e8B0);
        deployedAtBlock = block.number;
        chainSalt = keccak256(abi.encodePacked("LegendaryBarnacle_", block.chainid, block.timestamp, address(this)));
    }

    function setPlatformPaused(bool paused) external onlyOwner {
        platformPaused = paused;
        emit PlatformPauseToggled(paused);
    }

    function registerArtist(bytes32 handleHash) external whenNotPaused nonReentrant returns (uint256 artistId) {
        if (msg.sender == address(0)) revert LB_ZeroAddress();
        if (artistIdByAddress[msg.sender] != 0) revert LB_ArtistAlreadyRegistered();
        if (artistCounter >= MAX_ARTWORKS) revert LB_MaxArtworksExceeded();

        artistCounter++;
        artistId = artistCounter;
        artistIdByAddress[msg.sender] = artistId;
        artistProfiles[artistId] = ArtistProfile({
            artist: msg.sender,
            handleHash: handleHash,
            totalMints: 0,
            totalEarningsWei: 0,
            registeredAtBlock: block.number,
            active: true
        });
        _allArtistIds.push(artistId);
        emit ArtistRegistered(msg.sender, handleHash, artistId, block.number);
        return artistId;
    }

    function createGallery(bytes32 nameHash, uint256 commissionBps) external whenNotPaused nonReentrant returns (uint256 galleryId) {
        if (msg.sender == address(0)) revert LB_ZeroAddress();
        if (commissionBps > MAX_COMMISSION_BPS) revert LB_InvalidCommissionBps();
        if (galleryCounter >= MAX_GALLERIES) revert LB_MaxGalleriesExceeded();

        galleryCounter++;
        galleryId = galleryCounter;
        galleryRecords[galleryId] = GalleryRecord({
            curator: msg.sender,
            nameHash: nameHash,
            commissionBps: commissionBps,
            totalEarningsWei: 0,
            createdAtBlock: block.number,
            active: true
        });
        _allGalleryIds.push(galleryId);
        emit GalleryCreated(galleryId, msg.sender, nameHash, commissionBps, block.number);
        return galleryId;
    }

    function mintArtwork(
        uint256 galleryId,
        bytes32 metadataHash,
        uint256 mintPriceWei,
        uint256 royaltyBps,
        bytes32[] calldata traitKeys,
        bytes32[] calldata traitValues
    ) external payable whenNotPaused nonReentrant returns (uint256 artworkId) {
        if (msg.sender == address(0)) revert LB_ZeroAddress();
        uint256 aid = artistIdByAddress[msg.sender];
        if (aid == 0) revert LB_ArtistNotFound();
        if (!artistProfiles[aid].active) revert LB_ArtistNotFound();
        if (galleryId != 0) {
            if (galleryId > galleryCounter || !galleryRecords[galleryId].active) revert LB_GalleryNotFound();
        }
        if (royaltyBps > MAX_ROYALTY_BPS) revert LB_InvalidRoyaltyBps();
        if (traitKeys.length != traitValues.length || traitKeys.length > MAX_TRAITS_PER_ARTWORK) revert LB_MaxTraitsExceeded();
        if (artworkCounter >= MAX_ARTWORKS) revert LB_MaxArtworksExceeded();
        if (msg.value < mintPriceWei) revert LB_InsufficientPayment();

        artworkCounter++;
        artworkId = artworkCounter;
        artworkRecords[artworkId] = ArtworkRecord({
            artist: msg.sender,
            galleryId: galleryId,
            metadataHash: metadataHash,
            mintPriceWei: mintPriceWei,
            royaltyBps: royaltyBps,
            mintedAtBlock: block.number,
            currentOwner: msg.sender,
            listPriceWei: 0,
            listedAtGalleryId: 0,
            listed: false
        });
        artistProfiles[aid].totalMints++;
        artistProfiles[aid].totalEarningsWei += mintPriceWei;
        _allArtworkIds.push(artworkId);
        artworkIdsByArtist[aid].push(artworkId);
        if (galleryId != 0) artworkIdsByGallery[galleryId].push(artworkId);
        ownedArtworkIds[msg.sender].push(artworkId);

        for (uint256 i = 0; i < traitKeys.length; i++) {
            traitsByArtwork[artworkId].push(TraitPair({ key: traitKeys[i], value: traitValues[i] }));
            emit TraitRecorded(artworkId, traitKeys[i], traitValues[i], block.number);
        }

        if (mintPriceWei > 0) {
            pendingArtistProceeds[msg.sender] += mintPriceWei;
        }
        if (galleryId != 0 && galleryRecords[galleryId].commissionBps > 0 && mintPriceWei > 0) {
            uint256 galleryCut = (mintPriceWei * galleryRecords[galleryId].commissionBps) / BPS_DENOM;
            pendingGalleryProceeds[galleryId] += galleryCut;
            pendingArtistProceeds[msg.sender] -= galleryCut;
        }
        emit ArtworkMinted(artworkId, msg.sender, galleryId, metadataHash, mintPriceWei, block.number);
        return artworkId;
    }

    function listInGallery(uint256 artworkId, uint256 galleryId, uint256 listPriceWei) external whenNotPaused nonReentrant {
        ArtworkRecord storage aw = artworkRecords[artworkId];
        if (aw.currentOwner != msg.sender) revert LB_NotOwner();
        if (aw.listed) revert LB_AlreadyListed();
        if (galleryId == 0 || galleryId > galleryCounter || !galleryRecords[galleryId].active) revert LB_GalleryNotFound();
        if (galleryRecords[galleryId].curator != msg.sender) {
            if (aw.artist != msg.sender) revert LB_NotCurator();
        }
        aw.listedAtGalleryId = galleryId;
        aw.listPriceWei = listPriceWei;
        aw.listed = true;
        emit ArtworkListedInGallery(artworkId, galleryId, listPriceWei, block.number);
    }

    function delist(uint256 artworkId) external whenNotPaused nonReentrant {
        ArtworkRecord storage aw = artworkRecords[artworkId];
        if (aw.currentOwner != msg.sender) revert LB_NotOwner();
        if (!aw.listed) revert LB_NotListed();
        uint256 gid = aw.listedAtGalleryId;
        aw.listed = false;
        aw.listedAtGalleryId = 0;
        aw.listPriceWei = 0;
        emit ArtworkDelisted(artworkId, gid, block.number);
    }

    function purchaseArtwork(uint256 artworkId) external payable whenNotPaused nonReentrant {
        ArtworkRecord storage aw = artworkRecords[artworkId];
        if (!aw.listed) revert LB_NotListed();
        if (msg.value < aw.listPriceWei) revert LB_InsufficientPayment();
        address seller = aw.currentOwner;
        uint256 priceWei = aw.listPriceWei;
        uint256 galleryId = aw.listedAtGalleryId;
        uint256 royaltyWei = (priceWei * aw.royaltyBps) / BPS_DENOM;
        uint256 galleryShare = 0;
        if (galleryId != 0 && galleryRecords[galleryId].commissionBps > 0) {
            galleryShare = (priceWei * galleryRecords[galleryId].commissionBps) / BPS_DENOM;
            pendingGalleryProceeds[galleryId] += galleryShare;
            galleryRecords[galleryId].totalEarningsWei += galleryShare;
        }
        uint256 artistShare = royaltyWei;
        pendingArtistProceeds[aw.artist] += artistShare;
        uint256 toSeller = priceWei - royaltyWei - galleryShare;
        pendingArtistProceeds[seller] += toSeller;

        aw.currentOwner = msg.sender;
        aw.listed = false;
        aw.listedAtGalleryId = 0;
        aw.listPriceWei = 0;
        _removeFromOwned(seller, artworkId);
        ownedArtworkIds[msg.sender].push(artworkId);
        if (msg.value > priceWei) {
            (bool sent,) = msg.sender.call{value: msg.value - priceWei}("");
            if (!sent) revert LB_TransferFailed();
        }
        emit ArtworkPurchased(artworkId, msg.sender, seller, priceWei, artistShare, galleryShare, block.number);
    }

    function withdrawArtistProceeds() external nonReentrant {
        uint256 amount = pendingArtistProceeds[msg.sender];
        if (amount == 0) revert LB_ZeroAmount();
        pendingArtistProceeds[msg.sender] = 0;
        (bool sent,) = msg.sender.call{value: amount}("");
        if (!sent) revert LB_TransferFailed();
        emit ProceedsWithdrawn(msg.sender, amount, 1, block.number);
    }

    function withdrawGalleryProceeds(uint256 galleryId) external nonReentrant {
        if (galleryRecords[galleryId].curator != msg.sender) revert LB_NotCurator();
        uint256 amount = pendingGalleryProceeds[galleryId];
        if (amount == 0) revert LB_ZeroAmount();
        pendingGalleryProceeds[galleryId] = 0;
        (bool sent,) = msg.sender.call{value: amount}("");
        if (!sent) revert LB_TransferFailed();
        emit ProceedsWithdrawn(msg.sender, amount, 2, block.number);
    }

    function updateGalleryCurator(uint256 galleryId, address newCurator) external {
        if (galleryRecords[galleryId].curator != msg.sender) revert LB_NotCurator();
        if (newCurator == address(0)) revert LB_ZeroAddress();
        galleryRecords[galleryId].curator = newCurator;
        emit CuratorUpdated(galleryId, newCurator, block.number);
    }

    function _removeFromOwned(address owner_, uint256 artworkId) internal {
        uint256[] storage ids = ownedArtworkIds[owner_];
        for (uint256 i = 0; i < ids.length; i++) {
            if (ids[i] == artworkId) {
                ids[i] = ids[ids.length - 1];
                ids.pop();
                break;
            }
        }
    }

    function getArtistProfile(uint256 artistId) external view returns (
        address artist,
        bytes32 handleHash,
        uint256 totalMints,
        uint256 totalEarningsWei,
        uint256 registeredAtBlock,
        bool active
    ) {
        ArtistProfile storage ap = artistProfiles[artistId];
        return (ap.artist, ap.handleHash, ap.totalMints, ap.totalEarningsWei, ap.registeredAtBlock, ap.active);
    }

    function getArtworkRecord(uint256 artworkId) external view returns (
        address artist,
        uint256 galleryId,
        bytes32 metadataHash,
        uint256 mintPriceWei,
        uint256 royaltyBps,
        uint256 mintedAtBlock,
        address currentOwner,
        uint256 listPriceWei,
        uint256 listedAtGalleryId,
        bool listed
    ) {
        ArtworkRecord storage aw = artworkRecords[artworkId];
        return (
            aw.artist,
            aw.galleryId,
            aw.metadataHash,
            aw.mintPriceWei,
            aw.royaltyBps,
            aw.mintedAtBlock,
            aw.currentOwner,
            aw.listPriceWei,
            aw.listedAtGalleryId,
            aw.listed
        );
    }

    function getGalleryRecord(uint256 galleryId) external view returns (
        address curator,
        bytes32 nameHash,
        uint256 commissionBps,
        uint256 totalEarningsWei,
        uint256 createdAtBlock,
        bool active
    ) {
        GalleryRecord storage gr = galleryRecords[galleryId];
        return (gr.curator, gr.nameHash, gr.commissionBps, gr.totalEarningsWei, gr.createdAtBlock, gr.active);
    }

    function getTraits(uint256 artworkId) external view returns (bytes32[] memory keys, bytes32[] memory values) {
        TraitPair[] storage pairs = traitsByArtwork[artworkId];
        keys = new bytes32[](pairs.length);
        values = new bytes32[](pairs.length);
        for (uint256 i = 0; i < pairs.length; i++) {
            keys[i] = pairs[i].key;
            values[i] = pairs[i].value;
        }
        return (keys, values);
    }

    function getArtworkIdsByGallery(uint256 galleryId) external view returns (uint256[] memory) {
        return artworkIdsByGallery[galleryId];
    }

    function getArtworkIdsByArtist(uint256 artistId) external view returns (uint256[] memory) {
        return artworkIdsByArtist[artistId];
    }

    function getOwnedArtworkIds(address account) external view returns (uint256[] memory) {
        return ownedArtworkIds[account];
    }

    function getPendingArtistProceeds(address artist) external view returns (uint256) {
        return pendingArtistProceeds[artist];
    }

    function getPendingGalleryProceeds(uint256 galleryId) external view returns (uint256) {
        return pendingGalleryProceeds[galleryId];
    }

    function getArtistId(address account) external view returns (uint256) {
        return artistIdByAddress[account];
    }

    function isArtistRegistered(address account) external view returns (bool) {
        uint256 aid = artistIdByAddress[account];
        return aid != 0 && artistProfiles[aid].active;
    }

    function getAllArtistIds() external view returns (uint256[] memory) {
        return _allArtistIds;
    }

    function getAllGalleryIds() external view returns (uint256[] memory) {
        return _allGalleryIds;
    }

    function getAllArtworkIds() external view returns (uint256[] memory) {
        return _allArtworkIds;
    }

    function getConfigSnapshot() external view returns (
        address platformTreasury_,
        address genesisCurator_,
        uint256 deployedAtBlock_,
        uint256 artistCounter_,
        uint256 artworkCounter_,
        uint256 galleryCounter_,
        bool platformPaused_
    ) {
        return (
            platformTreasury,
            genesisCurator,
            deployedAtBlock,
            artistCounter,
            artworkCounter,
            galleryCounter,
            platformPaused
        );
    }

    function getConstantsSnapshot() external pure returns (
        uint256 bpsDenom,
        uint256 maxCommissionBps,
        uint256 maxRoyaltyBps,
        uint256 maxTraitsPerArtwork,
        uint256 maxGalleries,
        uint256 maxArtworks
    ) {
        return (BPS_DENOM, MAX_COMMISSION_BPS, MAX_ROYALTY_BPS, MAX_TRAITS_PER_ARTWORK, MAX_GALLERIES, MAX_ARTWORKS);
    }

    function getLegendarySeed() external pure returns (uint256) {
        return LEGENDARY_SEED;
    }

    function getChainSalt() external view returns (bytes32) {
        return chainSalt;
    }

    function getArtworkRecordBatch(uint256[] calldata artworkIds) external view returns (
        address[] memory artists,
        uint256[] memory galleryIds,
        bytes32[] memory metadataHashes,
        address[] memory currentOwners,
        uint256[] memory listPrices,
        bool[] memory listedFlags
    ) {
        uint256 n = artworkIds.length;
        artists = new address[](n);
        galleryIds = new uint256[](n);
        metadataHashes = new bytes32[](n);
        currentOwners = new address[](n);
        listPrices = new uint256[](n);
        listedFlags = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            ArtworkRecord storage aw = artworkRecords[artworkIds[i]];
            artists[i] = aw.artist;
            galleryIds[i] = aw.galleryId;
            metadataHashes[i] = aw.metadataHash;
            currentOwners[i] = aw.currentOwner;
            listPrices[i] = aw.listPriceWei;
            listedFlags[i] = aw.listed;
        }
        return (artists, galleryIds, metadataHashes, currentOwners, listPrices, listedFlags);
    }

    function getGalleryRecordBatch(uint256[] calldata galleryIds_) external view returns (
        address[] memory curators,
        bytes32[] memory nameHashes,
        uint256[] memory commissionBps,
        uint256[] memory totalEarnings,
        bool[] memory activeFlags
    ) {
        uint256 n = galleryIds_.length;
        curators = new address[](n);
        nameHashes = new bytes32[](n);
        commissionBps = new uint256[](n);
        totalEarnings = new uint256[](n);
        activeFlags = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            GalleryRecord storage gr = galleryRecords[galleryIds_[i]];
            curators[i] = gr.curator;
            nameHashes[i] = gr.nameHash;
            commissionBps[i] = gr.commissionBps;
            totalEarnings[i] = gr.totalEarningsWei;
            activeFlags[i] = gr.active;
        }
        return (curators, nameHashes, commissionBps, totalEarnings, activeFlags);
    }

    function getArtistProfileBatch(uint256[] calldata artistIds) external view returns (
        address[] memory artists,
        bytes32[] memory handleHashes,
        uint256[] memory totalMints,
        uint256[] memory totalEarnings,
        bool[] memory activeFlags
    ) {
        uint256 n = artistIds.length;
        artists = new address[](n);
        handleHashes = new bytes32[](n);
        totalMints = new uint256[](n);
        totalEarnings = new uint256[](n);
        activeFlags = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            ArtistProfile storage ap = artistProfiles[artistIds[i]];
            artists[i] = ap.artist;
            handleHashes[i] = ap.handleHash;
            totalMints[i] = ap.totalMints;
            totalEarnings[i] = ap.totalEarningsWei;
            activeFlags[i] = ap.active;
        }
        return (artists, handleHashes, totalMints, totalEarnings, activeFlags);
    }

    function listPriceForArtwork(uint256 artworkId) external view returns (uint256) {
        return artworkRecords[artworkId].listPriceWei;
    }

    function currentOwnerOf(uint256 artworkId) external view returns (address) {
        return artworkRecords[artworkId].currentOwner;
    }

    function isListed(uint256 artworkId) external view returns (bool) {
        return artworkRecords[artworkId].listed;
    }

    function traitCount(uint256 artworkId) external view returns (uint256) {
        return traitsByArtwork[artworkId].length;
    }

    function galleryArtworkCount(uint256 galleryId) external view returns (uint256) {
        return artworkIdsByGallery[galleryId].length;
    }

    function artistArtworkCount(uint256 artistId) external view returns (uint256) {
        return artworkIdsByArtist[artistId].length;
    }

    function totalArtworksMinted() external view returns (uint256) {
        return artworkCounter;
    }

    function totalGalleriesCreated() external view returns (uint256) {
        return galleryCounter;
    }

