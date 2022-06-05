// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Counters.sol";

contract LandSpace is ERC721, ERC721URIStorage, Ownable {
    using Counters for Counters.Counter;

    Counters.Counter private _tokenIdCounter;

    address payable contractOwner;

    uint auctionDuration;
    uint auctions;
    
    // penalty paid to contract owner when cancelling an auction
    uint cancelAuctionPenalty;


    event Start(address indexed owner, uint auctionId, uint tokenId);
    event Bid(address indexed sender, uint amount);
    event Refund(address indexed bidder, uint amount);
    event End(address winner, uint amount);
    event Cancel(address indexed owner, uint auctionId, uint tokenId);

    constructor() ERC721("Land Space", "LS") {
        auctionDuration = 10800;
        auctions = 0;
        cancelAuctionPenalty = 1 ether;
        contractOwner = payable(msg.sender);
    }

    struct Land {
        address payable owner;
        address bidder;
        uint currentBid;
        uint startingPrice;
        uint instantSellingPrice;
        bool forSale;
    }

    mapping(uint => Land) lands;
    // mapping that keeps track of auction ending time
    mapping(uint => uint) auctionEnd;
    mapping(uint => uint ) allAuctions;

    modifier isOwner(uint auctionId) {
        Land storage currentLand = lands[allAuctions[auctionId]];
        require(msg.sender == currentLand.owner, "You are not the owner");
        _;
    }

    modifier onSale(uint auctionId) {
        Land storage currentLand = lands[allAuctions[auctionId]];
        require(currentLand.forSale == true, "Your land isn't on sale");
        _;
    }

    modifier isOver(uint auctionId) {
        require(block.timestamp <= auctionEnd[auctionId], "The auction is over");
        _;
    }

    modifier canAuction(uint tokenId) {
        Land storage currentLand = lands[tokenId];
        require(msg.sender == currentLand.owner && msg.sender == currentLand.bidder, "You are not the owner");
        require(currentLand.forSale == false, "This land is already in an auction");
        require(currentLand.startingPrice == 0 && currentLand.instantSellingPrice == 0, "Land isn't available");
        _;
    }

    modifier canBid(uint auctionId) {
        Land storage currentLand = lands[allAuctions[auctionId]];
        require(msg.sender != currentLand.owner, "you can't bid on your land");
        require(msg.sender != currentLand.bidder, "You can't outbid yourself");
        require(msg.value > currentLand.currentBid && msg.value >= currentLand.startingPrice, "You need to bid higher than the current bid");
        _;
    }

    // utility function to reset some struct values when cancelling an auction
    function cancelBidHelper(uint auctionId) internal{
        Land storage currentLand = lands[allAuctions[auctionId]];
        currentLand.currentBid = 0;
        currentLand.bidder = msg.sender;
        currentLand.instantSellingPrice = 0;
        currentLand.startingPrice = 0;
        currentLand.forSale = false;
        emit Cancel(currentLand.owner, auctionId, allAuctions[auctionId]);
    }

    // utility function to assign new bidder and new bid
    function makeBidHelper(uint auctionId) internal{
        Land storage currentLand = lands[allAuctions[auctionId]];
        currentLand.currentBid = msg.value;
        currentLand.bidder = msg.sender;
        emit Bid(currentLand.bidder, currentLand.currentBid);
    }
    
    //utility function to make adjustment for new owner and to transfer ownership of NFT
    function endAuctionHelper(uint auctionId, uint _balanceBidder) internal{
        Land storage currentLand = lands[allAuctions[auctionId]];
        safeTransferFrom(currentLand.owner, currentLand.bidder, allAuctions[auctionId]);
        currentLand.forSale = false;
        currentLand.owner = payable(msg.sender);
        currentLand.startingPrice = 0;
        currentLand.instantSellingPrice = 0;
        emit End(currentLand.bidder, _balanceBidder);
    }

    // utility function to create Land
    function createLand(uint tokenId, address to) internal {
        uint currentBid = 0;
        uint startingPrice = 0;
        uint instantSellingPrice = 0;
        lands[tokenId] = Land(
                                payable(to),
                                to,
                                currentBid,
                                startingPrice,
                                instantSellingPrice,
                                false
                             );
    }

    function safeMint(address to, string memory uri) public {
        uint256 tokenId = _tokenIdCounter.current();
        _tokenIdCounter.increment();
        createLand(tokenId, to);
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, uri);
    }

    // users needs to enter the tokenId, a starting price and an instant selling price to start a new auction
    function startAuction(uint tokenId, uint _startingPrice, uint _instantSellingPrice) public canAuction(tokenId) {
        Land storage currentLand = lands[tokenId];
        currentLand.forSale = true;
        currentLand.startingPrice = _startingPrice;
        currentLand.instantSellingPrice = _instantSellingPrice;
        auctionEnd[auctions] = block.timestamp + auctionDuration;
        allAuctions[auctions] = tokenId;
        auctions++;
        emit Start(currentLand.owner ,  auctions, tokenId);
    }

    // makes sure that owner is the one calling the function, that the NFT is on sale and that the auction isn't yet over
    function cancelAuction(uint auctionId) public payable isOwner(auctionId) onSale(auctionId) isOver(auctionId){
        Land storage currentLand = lands[allAuctions[auctionId]];
        auctionEnd[auctionId] = 0;
        (bool success,) = contractOwner.call{value: cancelAuctionPenalty}(""); // penalty is paid to the contract owner
        require(success, "Transfer failed");
        // runs only if there is a current bid on the NFT
        if(currentLand.bidder != address(0) && currentLand.currentBid > 0) {
            uint refundValue = currentLand.currentBid;
            currentLand.currentBid = 0;
            (bool sent,) = payable(currentLand.bidder).call{value: refundValue}("");
            require(sent, "Transfer failed");
            cancelBidHelper(auctionId);
        }else {
            cancelBidHelper(auctionId); // reset some values of currentLand
        }
    }


    // makes sure that current user is viable to bid and that the auction isn't over
    function makeBid(uint auctionId) public payable isOver(auctionId) canBid(auctionId){
        Land storage currentLand = lands[allAuctions[auctionId]];
        uint balanceBidder = currentLand.currentBid;
        
        // this runs for every bid except if the bid is equal to the instant selling price
        if(balanceBidder > 0 && msg.value < currentLand.instantSellingPrice){
            currentLand.currentBid = 0;
            (bool success,) = payable(currentLand.bidder).call{value: balanceBidder}(""); // refund to previous bidder
            require(success, "Payment to previous bidder failed");
            makeBidHelper(auctionId);
            
         // this only runs for the first bidder   
        }else if (balanceBidder == 0 && msg.value < currentLand.instantSellingPrice){
            makeBidHelper(auctionId);
            
         // this runs if the new bid is equal to the instant selling price    
        }else {
            currentLand.currentBid = msg.value;
            balanceBidder = currentLand.currentBid;
            currentLand.currentBid = 0;
            (bool success,) = currentLand.owner.call{value: balanceBidder}(""); // selling bid is paid to the owner
            require(success, "You have failed to make full payment");
            currentLand.bidder = msg.sender;
            //NFT is approved for transfer of ownership
            _approve(msg.sender, allAuctions[auctionId]);
            endAuctionHelper(auctionId, balanceBidder);
        }
    }

     // Makes sure the owner is the one calling this function, the NFT is on sale and that the auction is already over
    function endAuction(uint auctionId) public payable isOwner(auctionId) onSale(auctionId){
        require(auctionId >=0 , "enter a correct auction id");
        Land storage currentLand = lands[allAuctions[auctionId]];
        require(block.timestamp >= auctionEnd[auctionId], "There is still time before you can end the auction");
        require(currentLand.currentBid != 0 && currentLand.bidder != currentLand.owner, "Your land isn't on sale");
        uint balanceBidder = currentLand.currentBid;
        currentLand.currentBid = 0;
        (bool success,) = currentLand.owner.call{value: balanceBidder}("");
        require(success, "You have failed to make full payment");
        endAuctionHelper(auctionId, balanceBidder);
    }


    function getLand(uint tokenId) public view returns (Land memory) {
        require(tokenId >=0 , "enter a correct token id");
        return lands[tokenId];
    }

    function getCancelAuctionPenalty() public view returns (uint) {
        return cancelAuctionPenalty;
    }
    
    function getauctionEnd(uint auctionId) public view returns (uint) {
        return auctionEnd[auctionId];
    }

    // The following functions are overrides required by Solidity.

    function _burn(uint256 tokenId) internal override(ERC721, ERC721URIStorage) {
        super._burn(tokenId);
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721, ERC721URIStorage)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }
}
