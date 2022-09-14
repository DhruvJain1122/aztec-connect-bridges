interface IManager {
    function getCurrentCycleIndex() external view returns (uint256);

    function getPools() external view returns (address[] memory);
}