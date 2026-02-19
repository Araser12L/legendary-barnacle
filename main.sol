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
