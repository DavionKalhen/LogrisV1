const { ethers } = require("ethers");

// Configuration: endpoint and contract address
const rpcEndpoint = "http://localhost:8545"; // URL to your Anvil node
const contractAddress = "0xA3dfCcbad1333DC69997Da28C961FF8B2879e653"; // Whitelist contract address

async function main() {
    // Connect to the network
    const provider = new ethers.JsonRpcProvider(rpcEndpoint);

    // Impersonate the admin account
    await provider.send("anvil_impersonateAccount", ["0x9e2b6378ee8ad2A4A95Fe481d63CAba8FB0EBBF9"]);

    // Create a signer
    const signer = await provider.getSigner("0x9e2b6378ee8ad2A4A95Fe481d63CAba8FB0EBBF9");
    // Create a custom interface for the add function
    const customAbi = ["function add(address)"];
    const contract = new ethers.Contract(contractAddress, customAbi, signer);

    // The address you want to whitelist
    const addressToWhitelist = "0xdB4471Db5086A62e04792DEe618f6bDE9a8A25d9";

    try {
        const tx = await contract.add("0xA3f7BF5b0fa93176c260BBa57ceE85525De2BaF4");
        console.log("Transaction hash:", tx.hash);
        await tx.wait();
        console.log("Address whitelisted successfully.");
        const tx2 = await contract.add(addressToWhitelist);  
        console.log("Transaction hash:", tx2.hash);
        await tx2.wait();
        console.log("Address whitelisted successfully."); 
    } catch (error) {
        console.error("Error whitelisting address:", error);
    }
}

main().catch(console.error);
