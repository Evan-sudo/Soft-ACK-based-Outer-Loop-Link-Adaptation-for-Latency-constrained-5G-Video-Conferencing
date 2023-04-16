# Soft-ACK-based-Outer-Loop-Link-Adaptation-for-Latency-constrained-5G-Video-Conferencing

## Introduction:

The high reliability and low latency requirements of multimedia services necessitate the design of more efficient link adaptation methods. In this project, we introduce instantaneous CSI reporting, specifically designed for 5G video conferencing, and enhance the outer loop link adaptation based on soft Acknowledgement (Soft-ACK). We also formulate a resource allocation problem in 5G physical downlink shared channel (PDSCH) to balance the uplink and downlink traffic in compliance with the specified latency constraints. Our proposed scheme operates in a relatively straightforward manner. It outperforms conventional link adaptation methods regarding Block-Level Error Rate (BLER) and effectively adheres to stringent latency constraints in video transmission simulations. This repository holds the main codes of our paper "Soft-ACK-based-Outer-Loop-Link-Adaptation-for-Latency-constrained-5G-Video-Conferencing"

## Testing:

- main_ins_snr.m is our proposed scheme for instantanesous CSI reporting, soft-ACK can also be enabled during the test.

- main_olla_RB.m include the downlink resource allocation strategy for efficient transmission under latency constraint

## Dataset:

- To run the 5G PDSCH  video transmission experiment, first convert the video segments to binary text files, the Python code can be found in /**video_codec**/**v2b** (change the path for accurate file access)

- We only listed part of the video representations, where the full database can be downloaded in: https://ece.uwaterloo.ca/~zduanmu/publications/tbc2018qoe/
