% function [txData, numTBs, video_len] = read_video (file, tbs_size)
%     txvid = load(file).';
%     video_len = length(txvid);
%     numTBs = ceil(length(txvid)/tbs_size);  % Number of TBs
%     pad_flag = mod(length(txvid),tbs_size);  % Check for padding
%     % Padding zeros at the last block
%     if pad_flag
%         padZeros = tbs_size-mod(length(txvid),tbs_size);    
%         txData = [txvid; zeros(padZeros,1)];
%     else 
%         txData = txvid;
%     end
% 
%     txData = reshape(txData,[tbs_size,numTBs]);
% end

function [txData, video_len] = read_video (file)
    txData = load(file).';
    video_len = length(txData);
end