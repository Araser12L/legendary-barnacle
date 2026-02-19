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
