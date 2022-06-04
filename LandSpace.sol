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

    modifier canBid(uint auctionId) {
        Land storage currentLand = lands[allAuctions[auctionId]];
        require(msg.sender != currentLand.owner, "you can't bid on your land");
        require(msg.value > currentLand.currentBid && msg.value >= currentLand.startingPrice, "You need to bid higher than the current bid");
        _;
    }

    function cancelBidHelper(uint auctionId) internal{
        Land storage currentLand = lands[allAuctions[auctionId]];
        currentLand.currentBid = 0;
        currentLand.bidder = msg.sender;
        currentLand.instantSellingPrice = 0;
        currentLand.startingPrice = 0;
        currentLand.forSale = false;
        emit Cancel(currentLand.owner, auctionId, allAuctions[auctionId]);
    }


    function makeBidHelper(uint auctionId) internal{
        Land storage currentLand = lands[allAuctions[auctionId]];
        currentLand.currentBid = msg.value;
        currentLand.bidder = msg.sender;
        emit Bid(currentLand.bidder, currentLand.currentBid);
    }

    function endAuctionHelper(uint auctionId, uint _balanceBidder) internal{
        Land storage currentLand = lands[allAuctions[auctionId]];
        safeTransferFrom(currentLand.owner, currentLand.bidder, allAuctions[auctionId]);
        currentLand.forSale = false;
        currentLand.owner = payable(msg.sender);
        currentLand.startingPrice = 0;
        currentLand.instantSellingPrice = 0;
        emit End(currentLand.bidder, _balanceBidder);
    }

    function safeMint(address to, string memory uri) public {
        uint256 tokenId = _tokenIdCounter.current();
        _tokenIdCounter.increment();
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
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, uri);
    }

    function startAuction(uint tokenId, uint _startingPrice, uint _instantSellingPrice) public {
        Land storage currentLand = lands[tokenId];
        require(msg.sender == currentLand.owner && msg.sender == currentLand.bidder, "You are not the owner");
        require(currentLand.forSale == false, "This land is already in an auction");
        require(currentLand.startingPrice == 0 && currentLand.instantSellingPrice == 0, "Land isn't available");
        currentLand.forSale = true; 
        currentLand.startingPrice = _startingPrice;
        currentLand.instantSellingPrice = _instantSellingPrice;
        auctionEnd[auctions] = block.timestamp + auctionDuration;
        allAuctions[auctions] = tokenId;
        auctions++;
        emit Start(currentLand.owner ,  auctions, tokenId);
    }

    // couple of errors and need to add an if/else statement
    function cancelAuction(uint auctionId) public payable isOwner(auctionId) onSale(auctionId) isOver(auctionId){
        Land storage currentLand = lands[allAuctions[auctionId]];
        auctionEnd[auctionId] = 0;
        (bool success,) = contractOwner.call{value: cancelAuctionPenalty}("");
        require(success, "Transfer failed");
        if(currentLand.bidder != address(0) && currentLand.currentBid > 0) {
            uint refundValue = currentLand.currentBid;
            currentLand.currentBid = 0;
            (bool sent,) = payable(currentLand.bidder).call{value: refundValue}("");
            require(sent, "Transfer failed");
            cancelBidHelper(auctionId);
        }else {
            cancelBidHelper(auctionId);
        }
    }



    function makeBid(uint auctionId) public payable isOver(auctionId) canBid(auctionId){
        Land storage currentLand = lands[allAuctions[auctionId]];
        uint balanceBidder = currentLand.currentBid;
        if(balanceBidder > 0 && msg.value < currentLand.instantSellingPrice){
            currentLand.currentBid = 0;
            (bool success,) = payable(currentLand.bidder).call{value: balanceBidder}("");
            require(success, "Your bidding payment has failed");
            makeBidHelper(auctionId);
        }else if (balanceBidder == 0 && msg.value < currentLand.instantSellingPrice){
            makeBidHelper(auctionId);
        }else {
            currentLand.currentBid = msg.value;
            balanceBidder = currentLand.currentBid;
            currentLand.currentBid = 0;
            (bool success,) = currentLand.owner.call{value: balanceBidder}("");
            require(success, "You have failed to make full payment");
            currentLand.bidder = msg.sender;
            _approve(msg.sender, allAuctions[auctionId]);
            endAuctionHelper(auctionId, balanceBidder);
        }
    }

    function endAuction(uint auctionId) public payable isOwner(auctionId) onSale(auctionId){
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
        return lands[tokenId];
    }

    function getcancelAuctionPenalty() public view returns (uint) {
        return cancelAuctionPenalty;
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
