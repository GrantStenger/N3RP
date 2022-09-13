// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.10;

import {RentalManager} from "../RentalManager.sol";
import {DSTestPlus} from "./utils/DSTestPlus.sol";
import {MockERC721} from "./mocks/MockERC721.sol";

import {stdError, stdStorage, StdStorage} from "forge-std/stdlib.sol";

contract RentalManagerTest is DSTestPlus {
    using stdStorage for StdStorage;

    RentalManager public rental;

    /// @dev Mock NFT
    MockERC721 public mockNft;

    /// @dev Mock Actors
    address public lenderAddress = address(69);
    address public borrowerAddress = address(420);

    /// @dev Owned ERC721 Token Id
    uint256 public tokenId = 1337;

    /// @dev Rental Parameters
    uint256 public cachedTimestamp = block.timestamp;
    uint256 public dueDate = cachedTimestamp + 100;
    uint256 public rentalPayment = 10;
    uint256 public collateral = 50;
    uint256 public collateralPayoutPeriod = 40;

    function setUp() public {
        // Create MockERC721
        mockNft = new MockERC721("Mock NFT", "MOCK");

        // Mint the lender the owned token id
        mockNft.mint(lenderAddress, tokenId);

        // Give the borrower enough balance
        vm.deal(borrowerAddress, type(uint256).max);

        // Create RentalManager
        rental = new RentalManager();

        rental.createRental(
            lenderAddress,
            borrowerAddress,
            address(mockNft),
            tokenId,
            dueDate,
            rentalPayment,
            collateral,
            collateralPayoutPeriod
        );
    }

    /// @notice Test Rental Creation
    function testCreateRental() public {
        // Expect Revert when we don't own the token id
        hoax(address(1));
        vm.expectRevert(abi.encodePacked(bytes4(keccak256("NonTokenOwner()"))));
        rental.createRental(
            address(1),
            borrowerAddress,
            address(mockNft),
            tokenId,
            dueDate,
            rentalPayment,
            collateral,
            collateralPayoutPeriod
        );

        // Expect Revert if the borrow doesn't have enough balance
        address lender = address(1);
        address borrower = address(2);
        hoax(lender);
        mockNft.mint(lender, tokenId + 1);
        vm.deal(borrower, rentalPayment + collateral - 1);
        vm.expectRevert(
            abi.encodePacked(bytes4(keccak256("InsufficientValue()")))
        );
        rental.createRental(
            lender,
            borrower,
            address(mockNft),
            tokenId + 1,
            dueDate,
            rentalPayment,
            collateral,
            collateralPayoutPeriod
        );
    }

    /// -------------------------------------------- ///
    /// ---------------- DEPOSIT NFT --------------- ///
    /// -------------------------------------------- ///

    /// @notice Tests depositing an NFT into the Rental Contract
    function testDepositNFT() public {
        // Expect Revert when we deposit to wrong rentalId
        startHoax(lenderAddress);
        vm.expectRevert(
            abi.encodePacked(bytes4(keccak256("InvalidRentalId()")))
        );
        rental.depositNft(1);
        vm.stopPrank();

        // Expect Revert when we don't send from the lender address
        startHoax(address(1));
        vm.expectRevert(abi.encodePacked(bytes4(keccak256("Unauthorized()"))));
        rental.depositNft(0);
        vm.stopPrank();

        // Expect Revert if the lender doesn't own the token
        startHoax(lenderAddress);
        mockNft.transferFrom(lenderAddress, address(1), tokenId);
        vm.expectRevert("WRONG_FROM");
        rental.depositNft(0);
        vm.stopPrank();

        // Transfer the token back to the lender
        hoax(address(1));
        mockNft.transferFrom(address(1), lenderAddress, tokenId);

        // The Rental can't transfer if we don't approve it
        hoax(lenderAddress);
        vm.expectRevert("NOT_AUTHORIZED");
        rental.depositNft(0);

        // Rental should not have any eth deposited at this point
        (, , , , bool ethIsDeposited, , , , , , , ) = rental.rentals(0);
        assertFalse(ethIsDeposited);

        // The Lender Can Deposit
        startHoax(lenderAddress);
        mockNft.approve(address(rental), tokenId);
        rental.depositNft(0);
        vm.stopPrank();

        // The rental should not have began since we didn't deposit eth
        (
            ,
            ,
            ,
            bool nftIsDeposited,
            ,
            ,
            ,
            ,
            ,
            ,
            uint256 rentalStartTime,
            uint256 collectedCollateral
        ) = rental.rentals(0);
        assertTrue(nftIsDeposited);
        assertEq(rentalStartTime, 0);
        assertEq(collectedCollateral, 0);

        // We can't redeposit now even if we get the token back somehow
        hoax(address(rental));
        mockNft.transferFrom(address(rental), lenderAddress, tokenId);
        hoax(lenderAddress);
        vm.expectRevert(
            abi.encodePacked(bytes4(keccak256("AlreadyDeposited()")))
        );
        rental.depositNft(0);
    }

    /// @notice Tests depositing the NFT into the contract after the borrower deposits eth
    function testDepositETHthenNFT() public {
        // Rental should not have any eth or nft deposited at this point
        (, , , bool nftIsDeposited, bool ethIsDeposited, , , , , , , ) = rental
            .rentals(0);
        assertFalse(nftIsDeposited);
        assertFalse(ethIsDeposited);

        // The Borrower can deposit eth
        hoax(borrowerAddress);
        rental.depositEth{value: rentalPayment + collateral}(0);

        // Eth should be deposited
        uint256 rentalStartTime;
        uint256 collectedCollateral;
        (
            ,
            ,
            ,
            nftIsDeposited,
            ethIsDeposited,
            ,
            ,
            ,
            ,
            ,
            rentalStartTime,
            collectedCollateral
        ) = rental.rentals(0);
        assertTrue(ethIsDeposited);
        assertFalse(nftIsDeposited);
        assertEq(rentalStartTime, 0);
        assertEq(collectedCollateral, 0);

        // The Lender Can Deposit
        startHoax(lenderAddress, 0);
        mockNft.approve(address(rental), tokenId);
        rental.depositNft(0);
        vm.stopPrank();

        // The rental should now begin!
        (
            ,
            ,
            ,
            nftIsDeposited,
            ethIsDeposited,
            ,
            ,
            ,
            ,
            ,
            rentalStartTime,

        ) = rental.rentals(0);
        assertTrue(nftIsDeposited);
        assertTrue(ethIsDeposited);

        assertEq(mockNft.ownerOf(tokenId), borrowerAddress);
        assertEq(lenderAddress.balance, rentalPayment);

        assertEq(rentalStartTime, block.timestamp);
    }

    /// -------------------------------------------- ///
    /// ---------------- DEPOSIT ETH --------------- ///
    /// -------------------------------------------- ///

    /// @notice Tests depositing ETH into the Rental Contract
    function testDepositETH() public {
        // Expect Revert when we don't send from the borrower address
        hoax(address(1));
        vm.expectRevert(abi.encodePacked(bytes4(keccak256("Unauthorized()"))));
        rental.depositEth(0);

        // Expect Revert if not enough eth is sent as a value
        hoax(borrowerAddress);
        vm.expectRevert(
            abi.encodePacked(bytes4(keccak256("InsufficientValue()")))
        );
        rental.depositEth(0);

        // Rental should not have any eth deposited at this point
        (, , , , bool ethIsDeposited, , , , , , , ) = rental.rentals(0);
        assertFalse(ethIsDeposited);

        // The Borrower can deposit eth
        hoax(borrowerAddress);
        rental.depositEth{value: rentalPayment + collateral}(0);

        // The rental should not have began since the lender hasn't deposited the nft
        (
            ,
            ,
            ,
            bool nftIsDeposited,
            bool ethIsDeposited2,
            ,
            ,
            ,
            ,
            ,
            uint256 rentalStartTime,

        ) = rental.rentals(0);
        assertTrue(ethIsDeposited2);
        assertFalse(nftIsDeposited);
        assertEq(rentalStartTime, 0);

        // We can't redeposit
        hoax(borrowerAddress);
        vm.expectRevert(
            abi.encodePacked(bytes4(keccak256("AlreadyDeposited()")))
        );
        rental.depositEth(0);
    }

    /// @notice Tests depositing ETH into the Rental Contract after the NFT is deposited
    function testDepositNFTandETH() public {
        // Rental should not have any eth or nft deposited at this point
        (, , , bool nftIsDeposited, bool ethIsDeposited, , , , , , , ) = rental
            .rentals(0);
        assertFalse(ethIsDeposited);
        assertFalse(nftIsDeposited);

        // The Lender Can Deposit
        startHoax(lenderAddress);
        mockNft.approve(address(rental), tokenId);
        rental.depositNft(0);
        vm.stopPrank();

        // The nft should be deposited
        (, , , nftIsDeposited, , , , , , , , ) = rental.rentals(0);
        assertTrue(nftIsDeposited);

        // Set the lender's balance to 0 to realize the eth transferred from the contract
        vm.deal(lenderAddress, 0);

        // The Borrower can deposit eth
        hoax(borrowerAddress);
        rental.depositEth{value: rentalPayment + collateral}(0);

        // The rental should now begin!
        uint256 rentalStartTime;
        (, , , nftIsDeposited, ethIsDeposited, , , , , , rentalStartTime, ) = rental.rentals(
            0
        );
        assertTrue(ethIsDeposited);
        assertTrue(nftIsDeposited);

        assert(mockNft.ownerOf(tokenId) == borrowerAddress);
        assert(lenderAddress.balance == rentalPayment);

        assert(rentalStartTime == block.timestamp);
    }

    /// -------------------------------------------- ///
    /// ---------------- WITHDRAW NFT -------------- ///
    /// -------------------------------------------- ///

    /// @notice Test Withdrawing NFT
    function testWithdrawNft() public {
        uint256 fullPayment = rentalPayment + collateral;

        // Can't withdraw if the nft hasn't been deposited
        hoax(lenderAddress);
        vm.expectRevert(abi.encodePacked(bytes4(keccak256("InvalidState()"))));
        rental.withdrawNft(0);

        // The Lender deposits
        startHoax(lenderAddress, fullPayment);
        mockNft.approve(address(rental), tokenId);
        rental.depositNft(0);
        vm.stopPrank();

        // Can't withdraw if not the lender
        hoax(address(1));
        vm.expectRevert(abi.encodePacked(bytes4(keccak256("Unauthorized()"))));
        rental.withdrawNft(0);

        // The Lender doesn't own the NFT here
        assertEq(mockNft.ownerOf(tokenId), address(rental));
    
        // The lender can withdraw the NFT
        hoax(lenderAddress, 0);
        rental.withdrawNft(0);

        // The Lender should now own the Token
        assertEq(mockNft.ownerOf(tokenId), lenderAddress);
    }

    /// -------------------------------------------- ///
    /// ---------------- WITHDRAW ETH -------------- ///
    /// -------------------------------------------- ///

    /// @notice Test Withdrawing ETH
    function testWithdrawETH() public {
        uint256 fullPayment = rentalPayment + collateral;

        // Can't withdraw if the eth hasn't been deposited
        hoax(borrowerAddress, fullPayment);
        vm.expectRevert(abi.encodePacked(bytes4(keccak256("InvalidState()"))));
        rental.withdrawEth(0);

        // The Borrower deposits
        hoax(borrowerAddress, fullPayment);
        rental.depositEth{value: fullPayment}(0);

        // Can't withdraw if not the borrower
        hoax(address(1));
        vm.expectRevert(abi.encodePacked(bytes4(keccak256("Unauthorized()"))));
        rental.withdrawEth(0);

        // Set both to have no eth
        vm.deal(borrowerAddress, 0);
    
        // The borrower can withdraw the full contract balance
        hoax(borrowerAddress, 0);
        rental.withdrawEth(0);

        // The borrower should have their full deposit returned
        assertEq(borrowerAddress.balance, fullPayment);
    }

    /// -------------------------------------------- ///
    /// ----------------- RETURN NFT --------------- ///
    /// -------------------------------------------- ///

    /// @notice Tests returning the NFT on time
    function testReturnNFT() public {
        // The Lender deposits
        startHoax(lenderAddress);
        mockNft.approve(address(rental), tokenId);
        rental.depositNft(0);
        vm.stopPrank();

        // The Borrower deposits
        hoax(borrowerAddress);
        rental.depositEth{value: rentalPayment + collateral}(0);

        // A non-owner of the erc721 token id shouldn't be able to transfer
        hoax(address(1));
        vm.expectRevert("WRONG_FROM");
        rental.returnNft(0);

        // Can't transfer without approval
        hoax(borrowerAddress);
        vm.expectRevert("NOT_AUTHORIZED");
        rental.returnNft(0);

        // The borrower should own the NFT now
        assertEq(mockNft.ownerOf(tokenId), borrowerAddress);
    
        // The owner should be able to return to the lender
        startHoax(borrowerAddress, 0);
        mockNft.approve(address(rental), tokenId);
        rental.returnNft(0);
        assertEq(borrowerAddress.balance, collateral);
        assertEq(mockNft.ownerOf(tokenId), lenderAddress);
        vm.stopPrank();
    }

    /// @notice Tests returning the NFT late
    function testReturnNFTLate() public {
        // The Lender deposits
        startHoax(lenderAddress);
        mockNft.approve(address(rental), tokenId);
        rental.depositNft(0);
        vm.stopPrank();

        // The Borrower deposits
        hoax(borrowerAddress);
        rental.depositEth{value: rentalPayment + collateral}(0);

        // A non-owner of the erc721 token id shouldn't be able to transfer
        hoax(address(1));
        vm.expectRevert("WRONG_FROM");
        rental.returnNft(0);

        // Can't transfer without approval
        startHoax(borrowerAddress);
        vm.expectRevert("NOT_AUTHORIZED");
        rental.returnNft(0);
        vm.stopPrank();

        // The borrower should own the NFT now
        assertEq(mockNft.ownerOf(tokenId), borrowerAddress);

        // Jump to between the dueDate and full collateral payout
        vm.warp(dueDate + collateralPayoutPeriod / 2);
    
        // Set the lender to have no eth
        vm.deal(lenderAddress, 0);

        // The owner should be able to return to the lender with a decreased collateral return
        startHoax(borrowerAddress, 0);
        mockNft.approve(address(rental), tokenId);
        rental.returnNft(0);
        assertEq(borrowerAddress.balance, collateral / 2);
        assertEq(lenderAddress.balance, collateral / 2);
        assertEq(mockNft.ownerOf(tokenId), lenderAddress);
        vm.stopPrank();
    }

    /// @notice Tests unable to return NFT since past collateral payout period
    function testReturnNFTFail() public {
        // The Lender deposits
        startHoax(lenderAddress);
        mockNft.approve(address(rental), tokenId);
        rental.depositNft(0);
        vm.stopPrank();

        // The Borrower deposits
        hoax(borrowerAddress);
        rental.depositEth{value: rentalPayment + collateral}(0);

        // The borrower should own the NFT now
        assertEq(mockNft.ownerOf(tokenId), borrowerAddress);

        // Jump to after the collateral payout period
        vm.warp(dueDate + collateralPayoutPeriod);

        // Set the lender to have no eth
        vm.deal(lenderAddress, 0);
    
        // The borrower can't return the nft now that it's past the payout period
        // Realistically, this wouldn't be called by the borrower since it just transfers the NFT back to the lender
        startHoax(borrowerAddress, 0);
        mockNft.approve(address(rental), tokenId);
        rental.returnNft(0);
        assertEq(borrowerAddress.balance, 0);
        assertEq(mockNft.ownerOf(tokenId), lenderAddress);
        assertEq(lenderAddress.balance, collateral);
        vm.stopPrank();
    }

    /// -------------------------------------------- ///
    /// ------------- WITHDRAW COLLATERAL ---------- ///
    /// -------------------------------------------- ///

    /// @notice Test withdrawing collateral
    function testWithdrawCollateral() public {
        // The Lender deposits
        startHoax(lenderAddress);
        mockNft.approve(address(rental), tokenId);
        rental.depositNft(0);
        vm.stopPrank();

        // The Borrower deposits
        hoax(borrowerAddress);
        rental.depositEth{value: rentalPayment + collateral}(0);

        // Can't withdraw collateral before the dueDate
        hoax(lenderAddress, 0);
        vm.expectRevert(abi.encodePacked(bytes4(keccak256("InvalidState()"))));
        rental.withdrawCollateral(0);

        // The borrower should own the NFT now
        assertEq(mockNft.ownerOf(tokenId), borrowerAddress);

        // Jump to after the collateral payout period
        vm.warp(dueDate + collateralPayoutPeriod);

        // Set both to have no eth
        vm.deal(lenderAddress, 0);
        vm.deal(borrowerAddress, 0);
    
        // The lender can withdraw the collateral
        startHoax(lenderAddress, 0);
        rental.withdrawCollateral(0);
        assertEq(borrowerAddress.balance, 0);
        assertEq(mockNft.ownerOf(tokenId), borrowerAddress);
        assertEq(lenderAddress.balance, collateral);
        vm.stopPrank();
    }

    /// @notice Test the borrower can withdraw the balance if the lender never deposits
    function testWithdrawCollateralNoLender() public {
        uint256 fullPayment = rentalPayment + collateral;
        // The Borrower deposits
        hoax(borrowerAddress, fullPayment);
        rental.depositEth{value: fullPayment}(0);

        // Can't withdraw collateral before the dueDate
        hoax(lenderAddress, 0);
        vm.expectRevert(abi.encodePacked(bytes4(keccak256("InvalidState()"))));
        rental.withdrawCollateral(0);

        // Jump to after the collateral payout period
        vm.warp(dueDate + collateralPayoutPeriod);

        // Set both to have no eth
        vm.deal(lenderAddress, 0);
        vm.deal(borrowerAddress, 0);
    
        // The borrower can withdraw the full contract balance
        hoax(borrowerAddress, 0);
        rental.withdrawCollateral(0);
        assertEq(borrowerAddress.balance, fullPayment);
    }
}
