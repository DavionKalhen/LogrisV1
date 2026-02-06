// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import "../src/converters/WETHToWstETHConverter.sol";

contract WETHToWstETHConverterConfigTest is Test {
    function testConstructorSetsConfig() public {
        address weth = address(0x1111);
        address steth = address(0x2222);
        address wsteth = address(0x3333);
        address curvePool = address(0x4444);

        WETHToWstETHConverter converter = new WETHToWstETHConverter(
            weth,
            steth,
            wsteth,
            curvePool,
            0,
            1,
            9950
        );

        assertEq(converter.underlyingToken(), weth);
        assertEq(converter.yieldToken(), wsteth);
        assertEq(converter.CURVE_STETH_POOL(), curvePool);
        assertEq(converter.minOutBps(), 9950);
    }

    function testConstructorRejectsInvalidMinOutBps() public {
        vm.expectRevert("Invalid minOutBps");
        new WETHToWstETHConverter(
            address(0x1111),
            address(0x2222),
            address(0x3333),
            address(0x4444),
            0,
            1,
            0
        );
    }

    function testConstructorRejectsHighMinOutBps() public {
        vm.expectRevert("Invalid minOutBps");
        new WETHToWstETHConverter(
            address(0x1111),
            address(0x2222),
            address(0x3333),
            address(0x4444),
            0,
            1,
            10001
        );
    }

    function testConstructorRejectsZeroWeth() public {
        vm.expectRevert("Invalid WETH");
        new WETHToWstETHConverter(
            address(0),
            address(0x2222),
            address(0x3333),
            address(0x4444),
            0,
            1,
            9950
        );
    }

    function testConstructorRejectsZeroCurvePool() public {
        vm.expectRevert("Invalid Curve pool");
        new WETHToWstETHConverter(
            address(0x1111),
            address(0x2222),
            address(0x3333),
            address(0),
            0,
            1,
            9950
        );
    }
}
